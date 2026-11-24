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
   * @brief User-selected installation options gathered from the initial dialog.
   */
  struct InstallOptions {
    bool proceed = false;
    bool replace_existing = true;
    bool quit_running = true;
    bool launch_after = true;
    bool delete_dmg = false;
  };

  /**
   * @brief Display a single initial dialog with checkboxes for all applicable install confirmations.
   *
   * @param has_existing Whether Lumax.app already exists in /Applications.
   * @param is_running Whether any Lumax instance is currently running.
   * @param dmg_name Filename of the backing .dmg image, or nil if not detected.
   * @return Populated InstallOptions with proceed=true if Install was clicked.
   */
  InstallOptions show_install_options_dialog(
    const bool has_existing,
    const bool is_running,
    NSString *const dmg_name
  ) {
    InstallOptions opts;
    [NSApp activateIgnoringOtherApps:YES];

    NSAlert *const alert = [[NSAlert alloc] init];
    alert.alertStyle = NSAlertStyleInformational;
    alert.messageText = has_existing ? [NSString stringWithFormat:@"Update %@", kAppName] : [NSString stringWithFormat:@"Install %@", kAppName];
    alert.informativeText = has_existing
      ? [NSString stringWithFormat:@"%@ already exists in Applications. Select the actions to perform:", kAppBundleName]
      : [NSString stringWithFormat:@"%@ will be installed to Applications. Select the actions to perform:", kAppBundleName];
    [alert addButtonWithTitle:@"Install"];
    [alert addButtonWithTitle:@"Cancel"];

    NSStackView *const stack = [[NSStackView alloc] init];
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.alignment = NSLayoutAttributeLeading;
    stack.spacing = 6.0;

    NSButton *replace_cb = nil;
    if (has_existing) {
      replace_cb = [NSButton checkboxWithTitle:[NSString stringWithFormat:@"Replace existing %@ in Applications", kAppBundleName]
                                        target:nil
                                        action:nil];
      replace_cb.state = NSControlStateValueOn;
      [stack addArrangedSubview:replace_cb];
    }

    NSButton *quit_cb = nil;
    if (is_running) {
      quit_cb = [NSButton checkboxWithTitle:[NSString stringWithFormat:@"Quit currently running %@", kAppName]
                                     target:nil
                                     action:nil];
      quit_cb.state = NSControlStateValueOn;
      [stack addArrangedSubview:quit_cb];
    }

    NSButton *const launch_cb = [NSButton checkboxWithTitle:[NSString stringWithFormat:@"Launch %@ after installation", kAppName]
                                                     target:nil
                                                     action:nil];
    launch_cb.state = NSControlStateValueOn;
    [stack addArrangedSubview:launch_cb];

    NSButton *delete_cb = nil;
    if (dmg_name != nil) {
      delete_cb = [NSButton checkboxWithTitle:[NSString stringWithFormat:@"Delete disk image (%@) after ejecting", dmg_name]
                                       target:nil
                                       action:nil];
      delete_cb.state = NSControlStateValueOff;
      [stack addArrangedSubview:delete_cb];
    }

    const NSSize fitting = stack.fittingSize;
    stack.frame = NSMakeRect(0, 0, MAX(fitting.width, 340.0), fitting.height);
    alert.accessoryView = stack;

    if ([alert runModal] != NSAlertFirstButtonReturn) {
      return opts;
    }

    opts.proceed = true;
    opts.replace_existing = replace_cb ? (replace_cb.state == NSControlStateValueOn) : true;
    opts.quit_running = quit_cb ? (quit_cb.state == NSControlStateValueOn) : false;
    opts.launch_after = (launch_cb.state == NSControlStateValueOn);
    opts.delete_dmg = delete_cb ? (delete_cb.state == NSControlStateValueOn) : false;
    return opts;
  }

  /**
   * @brief Terminate running Lumax instances and wait for exit.
   *
   * @param running Non-empty list of running Lumax instances.
   * @return true if all instances exited; false if termination failed.
   */
  bool terminate_running_lumax(NSArray<NSRunningApplication *> *const running) {

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

    const bool has_existing = [[NSFileManager defaultManager] fileExistsAtPath:target_path];
    NSArray<NSRunningApplication *> *const running = find_running_lumax(target_path);
    NSString *const dmg_path = find_dmg_image_path(mount_root);

    // 1. Show a single dialog with checkboxes for all applicable confirmations.
    const InstallOptions opts = show_install_options_dialog(
      has_existing,
      running.count > 0,
      dmg_path ? [dmg_path lastPathComponent] : nil
    );
    if (!opts.proceed || (has_existing && !opts.replace_existing)) {
      return 0;
    }

    // 2. Quit running Lumax if requested.
    if (running.count > 0 && opts.quit_running && !terminate_running_lumax(running)) {
      return 0;
    }

    // 3. Copy Lumax.app into /Applications.
    if (!copy_bundle_to_applications(source_path, target_path)) {
      return 1;
    }

    // 4. Launch Lumax if requested.
    if (opts.launch_after) {
      launch_installed_app(target_path);
    }

    // 5. Delete the .dmg file if requested.
    if (dmg_path != nil && opts.delete_dmg) {
      delete_dmg_file(dmg_path);
    }

    // 6. Detach/eject the mounted DMG once this process exits.
    schedule_volume_eject(mount_root);
  }
  return 0;
}
