/**
 * @file src_assets/macos/installer/install_lumax.mm
 * @brief Native macOS DMG installer application for Lumax.
 */

// system includes
#import <Cocoa/Cocoa.h>
#include <dispatch/dispatch.h>
#include <unistd.h>

namespace {
  constexpr NSString *const kAppName = @"Lumax";
  constexpr NSString *const kAppBundleName = @"Lumax.app";
  constexpr NSString *const kAppBundleId = @PROJECT_FQDN;
  constexpr NSString *const kPayloadSubdir = @".Lumax";
  constexpr NSString *const kApplicationsDir = @"/Applications";

  /**
   * @brief Display a modal alert on the active application and return the clicked button response.
   *
   * @param style Alert severity style.
   * @param title Main message text.
   * @param info Informative body text.
   * @param primary Primary (default) button title.
   * @param secondary Optional secondary button title, or nil for a single-button alert.
   * @return NSModalResponse from runModal.
   */
  NSModalResponse show_alert(
    const NSAlertStyle style,
    NSString *const title,
    NSString *const info,
    NSString *const primary,
    NSString *const secondary
  ) {
    [NSApp activateIgnoringOtherApps:YES];
    NSAlert *alert = [[NSAlert alloc] init];
    alert.alertStyle = style;
    alert.messageText = title;
    alert.informativeText = info;
    [alert addButtonWithTitle:primary];
    if (secondary != nil) {
      [alert addButtonWithTitle:secondary];
    }
    return [alert runModal];
  }

  /**
   * @brief Run a process synchronously and return its exit status.
   *
   * @param launch_path Executable path.
   * @param arguments Command arguments.
   * @return Exit status, or -1 if the task failed to launch.
   */
  int run_task(NSString *const launch_path, NSArray<NSString *> *const arguments) {
    NSTask *task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:launch_path];
    task.arguments = arguments;
    task.standardOutput = [NSFileHandle fileHandleWithNullDevice];
    task.standardError = [NSFileHandle fileHandleWithNullDevice];
    NSError *error = nil;
    if (![task launchAndReturnError:&error]) {
      return -1;
    }
    [task waitUntilExit];
    return task.terminationStatus;
  }

  /**
   * @brief Quote a string for safe single-quoted POSIX shell usage.
   *
   * @param value Raw string.
   * @return Shell-escaped single-quoted string.
   */
  NSString *shell_quote(NSString *const value) {
    NSString *escaped = [value stringByReplacingOccurrencesOfString:@"'" withString:@"'\\''"];
    return [NSString stringWithFormat:@"'%@'", escaped];
  }

  /**
   * @brief Find any currently running instances of Lumax.
   *
   * @param target_path Installed application path in /Applications.
   * @return Array of matching running applications.
   */
  NSArray<NSRunningApplication *> *find_running_lumax(NSString *const target_path) {
    NSMutableArray<NSRunningApplication *> *matches = [NSMutableArray array];
    NSArray<NSRunningApplication *> *by_id =
      [NSRunningApplication runningApplicationsWithBundleIdentifier:kAppBundleId];
    [matches addObjectsFromArray:by_id];

    NSURL *const target_url = [[NSURL fileURLWithPath:target_path] URLByStandardizingPath];
    for (NSRunningApplication *app in [[NSWorkspace sharedWorkspace] runningApplications]) {
      NSURL *const app_url = [app.bundleURL URLByStandardizingPath];
      if (app_url != nil && [app_url isEqual:target_url] && ![matches containsObject:app]) {
        [matches addObject:app];
      }
    }
    return matches;
  }

  /**
   * @brief Prompt the user to quit running Lumax instances and wait for termination.
   *
   * @param running Non-empty list of running Lumax instances.
   * @return true if all instances exited; false if the user cancelled or termination failed.
   */
  bool quit_running_lumax(NSArray<NSRunningApplication *> *const running) {
    const NSModalResponse resp = show_alert(
      NSAlertStyleWarning,
      [NSString stringWithFormat:@"%@ is currently running", kAppName],
      [NSString stringWithFormat:@"%@ must be closed before installing. Do you want to quit %@ now?", kAppName, kAppName],
      [NSString stringWithFormat:@"Quit %@", kAppName],
      @"Cancel"
    );
    if (resp != NSAlertFirstButtonReturn) {
      return false;
    }

    for (NSRunningApplication *app in running) {
      [app terminate];
    }

    NSDate *const deadline = [NSDate dateWithTimeIntervalSinceNow:5.0];
    while ([deadline timeIntervalSinceNow] > 0) {
      bool any_alive = false;
      for (NSRunningApplication *app in running) {
        if (!app.terminated) {
          any_alive = true;
          break;
        }
      }
      if (!any_alive) {
        return true;
      }
      [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
    }

    for (NSRunningApplication *app in running) {
      if (!app.terminated) {
        [app forceTerminate];
      }
    }

    NSDate *const force_deadline = [NSDate dateWithTimeIntervalSinceNow:2.0];
    while ([force_deadline timeIntervalSinceNow] > 0) {
      bool any_alive = false;
      for (NSRunningApplication *app in running) {
        if (!app.terminated) {
          any_alive = true;
          break;
        }
      }
      if (!any_alive) {
        return true;
      }
      [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
    }

    show_alert(
      NSAlertStyleCritical,
      [NSString stringWithFormat:@"Could not quit %@", kAppName],
      [NSString stringWithFormat:@"Please quit %@ manually and run the installer again.", kAppName],
      @"OK",
      nil
    );
    return false;
  }

  /**
   * @brief Copy the application bundle into /Applications, elevating with an admin prompt if needed.
   *
   * @param source_path Path to the bundled Lumax.app on the disk image.
   * @param target_path Destination path in /Applications.
   * @return true on success; false if cancelled or failed.
   */
  bool copy_bundle_to_applications(NSString *const source_path, NSString *const target_path) {
    NSFileManager *const fm = [NSFileManager defaultManager];
    const bool dest_writable =
      [fm isWritableFileAtPath:kApplicationsDir] &&
      (![fm fileExistsAtPath:target_path] || [fm isDeletableFileAtPath:target_path]);

    if (dest_writable) {
      if ([fm fileExistsAtPath:target_path]) {
        NSError *remove_err = nil;
        if (![fm removeItemAtPath:target_path error:&remove_err]) {
          show_alert(
            NSAlertStyleCritical,
            @"Installation Failed",
            [NSString stringWithFormat:@"Could not remove existing %@: %@", kAppBundleName, remove_err.localizedDescription],
            @"OK",
            nil
          );
          return false;
        }
      }
      if (run_task(@"/usr/bin/ditto", @[source_path, target_path]) == 0) {
        run_task(@"/usr/bin/xattr", @[@"-dr", @"com.apple.quarantine", target_path]);
        return true;
      }
    }

    // Fall back to AppleScript administrator prompt when /Applications is not user-writable.
    NSString *const shell_cmd = [NSString
      stringWithFormat:@"/bin/rm -rf %@ && /usr/bin/ditto %@ %@ && (/usr/bin/xattr -dr com.apple.quarantine %@ || true)",
                       shell_quote(target_path),
                       shell_quote(source_path),
                       shell_quote(target_path),
                       shell_quote(target_path)];
    NSString *const escaped_cmd = [[shell_cmd stringByReplacingOccurrencesOfString:@"\\" withString:@"\\\\"]
      stringByReplacingOccurrencesOfString:@"\"" withString:@"\\\""];
    NSString *const script_src = [NSString stringWithFormat:@"do shell script \"%@\" with administrator privileges", escaped_cmd];

    NSAppleScript *const script = [[NSAppleScript alloc] initWithSource:script_src];
    NSDictionary<NSString *, id> *err_info = nil;
    if ([script executeAndReturnError:&err_info] == nil) {
      NSNumber *const err_num = err_info[NSAppleScriptErrorNumber];
      if (err_num != nil && err_num.integerValue == -128) {
        // User cancelled the authentication dialog.
        return false;
      }
      NSString *const msg = err_info[NSAppleScriptErrorMessage] ?: @"Administrator installation failed.";
      show_alert(NSAlertStyleCritical, @"Installation Failed", msg, @"OK", nil);
      return false;
    }
    return true;
  }

  /**
   * @brief Launch the newly installed Lumax.app.
   *
   * @param target_path Installed application path in /Applications.
   */
  void launch_installed_app(NSString *const target_path) {
    NSURL *const app_url = [NSURL fileURLWithPath:target_path];
    NSWorkspaceOpenConfiguration *const config = [NSWorkspaceOpenConfiguration configuration];
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    [[NSWorkspace sharedWorkspace]
      openApplicationAtURL:app_url
             configuration:config
         completionHandler:^(NSRunningApplication * _Nullable app, NSError * _Nullable error) {
           (void) app;
           (void) error;
           dispatch_semaphore_signal(sem);
         }];
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC));
  }

  /**
   * @brief Resolve the backing .dmg file path for a mounted volume via `hdiutil info -plist`.
   *
   * @param mount_path Mounted volume path under /Volumes.
   * @return Path to the .dmg file if found and existing, or nil.
   */
  NSString *find_dmg_image_path(NSString *const mount_path) {
    if (![mount_path hasPrefix:@"/Volumes/"]) {
      return nil;
    }
    NSTask *const task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:@"/usr/bin/hdiutil"];
    task.arguments = @[@"info", @"-plist"];
    NSPipe *const out_pipe = [NSPipe pipe];
    task.standardOutput = out_pipe;
    task.standardError = [NSFileHandle fileHandleWithNullDevice];
    if (![task launchAndReturnError:nil]) {
      return nil;
    }
    NSData *const plist_data = [[out_pipe fileHandleForReading] readDataToEndOfFile];
    [task waitUntilExit];
    if (task.terminationStatus != 0 || plist_data.length == 0) {
      return nil;
    }

    id parsed = [NSPropertyListSerialization propertyListWithData:plist_data
                                                          options:NSPropertyListImmutable
                                                           format:nil
                                                            error:nil];
    if (![parsed isKindOfClass:[NSDictionary class]]) {
      return nil;
    }
    NSArray *const images = parsed[@"images"];
    if (![images isKindOfClass:[NSArray class]]) {
      return nil;
    }

    NSString *const normalized_mount = [mount_path stringByStandardizingPath];
    for (id item in images) {
      if (![item isKindOfClass:[NSDictionary class]]) {
        continue;
      }
      NSArray *const entities = item[@"system-entities"];
      if (![entities isKindOfClass:[NSArray class]]) {
        continue;
      }
      for (id entity in entities) {
        if (![entity isKindOfClass:[NSDictionary class]]) {
          continue;
        }
        NSString *const mp = entity[@"mount-point"];
        if ([mp isKindOfClass:[NSString class]] && [[mp stringByStandardizingPath] isEqualToString:normalized_mount]) {
          NSString *const img_path = item[@"image-path"];
          if ([img_path isKindOfClass:[NSString class]] &&
              [[img_path lowercaseString] hasSuffix:@".dmg"] &&
              [[NSFileManager defaultManager] fileExistsAtPath:img_path]) {
            return img_path;
          }
        }
      }
    }
    return nil;
  }

  /**
   * @brief Delete the backing .dmg file before ejecting (unlinks cleanly on APFS/HFS+ while mounted).
   *
   * @param dmg_path Path to the .dmg file on disk.
   */
  void delete_dmg_file(NSString *const dmg_path) {
    NSFileManager *const fm = [NSFileManager defaultManager];
    NSError *err = nil;
    if ([fm removeItemAtPath:dmg_path error:&err]) {
      return;
    }
    show_alert(
      NSAlertStyleWarning,
      @"Could not delete disk image",
      [NSString stringWithFormat:@"%@ could not be deleted: %@", [dmg_path lastPathComponent], err.localizedDescription],
      @"OK",
      nil
    );
  }

  /**
   * @brief Launch a detached background task to eject the DMG volume after this process exits.
   *
   * @param mount_path Path to the mounted DMG volume under /Volumes.
   */
  void schedule_volume_eject(NSString *const mount_path) {
    if (![mount_path hasPrefix:@"/Volumes/"]) {
      return;
    }
    NSString *const eject_script =
      @"sleep 1; "
      "for i in 1 2 3 4 5 6 7 8 9 10; do "
      "  /usr/sbin/diskutil eject \"$1\" >/dev/null 2>&1 && exit 0; "
      "  /usr/bin/hdiutil detach \"$1\" -quiet >/dev/null 2>&1 && exit 0; "
      "  sleep 1; "
      "done; "
      "/usr/bin/hdiutil detach \"$1\" -force -quiet >/dev/null 2>&1";
    NSTask *const task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:@"/bin/sh"];
    task.arguments = @[
      @"-c",
      eject_script,
      @"sh",
      mount_path
    ];
    task.standardInput = [NSFileHandle fileHandleWithNullDevice];
    task.standardOutput = [NSFileHandle fileHandleWithNullDevice];
    task.standardError = [NSFileHandle fileHandleWithNullDevice];
    [task launchAndReturnError:nil];
  }
}  // namespace

/**
 * @brief Entry point for the Install Lumax macOS installer application.
 *
 * @param argc Argument count.
 * @param argv Argument vector.
 * @return Process exit code.
 */
int main(int argc, const char *argv[]) {
  (void) argc;
  (void) argv;
  @autoreleasepool {
    [NSApplication sharedApplication];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];

    NSString *const bundle_path = [[NSBundle mainBundle] bundlePath];
    NSString *const mount_root = [bundle_path stringByDeletingLastPathComponent];
    NSString *const source_path = [[mount_root stringByAppendingPathComponent:kPayloadSubdir]
      stringByAppendingPathComponent:kAppBundleName];
    NSString *const target_path = [kApplicationsDir stringByAppendingPathComponent:kAppBundleName];

    if (![[NSFileManager defaultManager] fileExistsAtPath:source_path]) {
      show_alert(
        NSAlertStyleCritical,
        [NSString stringWithFormat:@"Cannot find %@", kAppBundleName],
        [NSString stringWithFormat:@"Please run this installer directly from the %@ disk image.", kAppName],
        @"OK",
        nil
      );
      return 1;
    }

    // 1. If Lumax.app already exists in /Applications, ask to replace or cancel.
    if ([[NSFileManager defaultManager] fileExistsAtPath:target_path]) {
      const NSModalResponse replace_resp = show_alert(
        NSAlertStyleInformational,
        [NSString stringWithFormat:@"%@ is already installed", kAppName],
        [NSString stringWithFormat:@"\"%@\" already exists in Applications. Do you want to replace it?", kAppBundleName],
        @"Replace",
        @"Cancel"
      );
      if (replace_resp != NSAlertFirstButtonReturn) {
        return 0;
      }
    }

    // 2. If Lumax is currently running, ask whether to quit it before replacing.
    NSArray<NSRunningApplication *> *const running = find_running_lumax(target_path);
    if (running.count > 0 && !quit_running_lumax(running)) {
      return 0;
    }

    // 3. Copy Lumax.app into /Applications.
    if (!copy_bundle_to_applications(source_path, target_path)) {
      return 1;
    }

    // 4. Ask whether to launch Lumax now.
    const NSModalResponse launch_resp = show_alert(
      NSAlertStyleInformational,
      [NSString stringWithFormat:@"%@ has been installed", kAppName],
      [NSString stringWithFormat:@"%@ was installed to Applications. Would you like to launch %@ now?", kAppBundleName, kAppName],
      [NSString stringWithFormat:@"Launch %@", kAppName],
      @"Done"
    );
    if (launch_resp == NSAlertFirstButtonReturn) {
      launch_installed_app(target_path);
    }

    // 5. Ask whether to delete the .dmg file.
    NSString *const dmg_path = find_dmg_image_path(mount_root);
    if (dmg_path != nil) {
      const NSModalResponse delete_resp = show_alert(
        NSAlertStyleInformational,
        @"Delete disk image?",
        [NSString stringWithFormat:@"Do you want to delete \"%@\" after ejecting?", [dmg_path lastPathComponent]],
        @"Keep",
        @"Delete"
      );
      if (delete_resp == NSAlertSecondButtonReturn) {
        delete_dmg_file(dmg_path);
      }
    }

    // 6. Detach/eject the mounted DMG once this process exits.
    schedule_volume_eject(mount_root);
  }
  return 0;
}
