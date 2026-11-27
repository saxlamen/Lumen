/**
 * @file src/platform/macos/tray_macos.mm
 * @brief Native AppKit system tray implementation for macOS.
 */
// standard includes
#include <atomic>
#include <cstring>
#include <mutex>
#include <string>

// platform includes
#import <AppKit/AppKit.h>
#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>
#import <UserNotifications/UserNotifications.h>
#include <dispatch/dispatch.h>

// lib includes
#include <tray.h>

@interface LumaxTrayDelegate : NSObject <UNUserNotificationCenterDelegate>
- (void)menuItemClicked:(NSMenuItem *)sender;
@end

namespace {

  std::atomic_bool g_should_exit {false};
  std::mutex g_tray_mutex;
  NSStatusItem *g_status_item = nil;
  LumaxTrayDelegate *g_delegate = nil;
  void (*g_log_callback)(int level, const char *msg) = nullptr;
  void (*g_last_notification_cb)() = nullptr;
  struct tray *g_current_tray = nullptr;
#ifdef TRAY_ENABLE_TEST_HOOKS
  NSPoint g_saved_mouse_pos {0, 0};
  bool g_has_saved_mouse_pos = false;
#endif

  /**
   * @brief Forward a message to the registered tray log callback, if any.
   *
   * @param level Severity level (0=debug, 1=info, 2=warning, 3=error).
   * @param msg Null-terminated log message.
   */
  void tray_log(const int level, const char *msg) {
    if (g_log_callback && msg) {
      g_log_callback(level, msg);
    }
  }

  /**
   * @brief Run a block synchronously on the main thread if already there, or asynchronously on the main queue.
   *
   * @param block Objective-C block to execute on the main thread.
   */
  void run_on_main_async(dispatch_block_t block) {
    if ([NSThread isMainThread]) {
      block();
    } else {
      dispatch_async(dispatch_get_main_queue(), block);
    }
  }

  /**
   * @brief Load a tray icon image directly from disk, falling back to PNG siblings if needed.
   *
   * @param icon_path Filesystem path to the icon resource.
   * @return Loaded NSImage sized for the macOS menu bar, or nil on failure.
   */
  NSImage *load_tray_image(const char *icon_path) {
    if (!icon_path || !*icon_path) {
      return nil;
    }

    NSString *path = [NSString stringWithUTF8String:icon_path];
    NSImage *image = [[NSImage alloc] initWithContentsOfFile:path];
    if (image && ![image isValid]) {
      image = nil;
    }

    if (!image && [[path pathExtension] caseInsensitiveCompare:@"svg"] == NSOrderedSame) {
      NSString *stem = [path stringByDeletingPathExtension];
      NSArray<NSString *> *candidates = @[
        [stem stringByAppendingString:@"-45.png"],
        [stem stringByAppendingString:@"-16.png"],
        [stem stringByAppendingString:@".png"],
      ];
      NSFileManager *fm = [NSFileManager defaultManager];
      for (NSString *candidate in candidates) {
        if ([fm fileExistsAtPath:candidate]) {
          image = [[NSImage alloc] initWithContentsOfFile:candidate];
          if (image && [image isValid]) {
            break;
          }
          image = nil;
        }
      }
    }

    if (!image) {
      image = [[NSApp applicationIconImage] copy];
    }
    if (image) {
      [image setSize:NSMakeSize(18.0, 18.0)];
      [image setTemplate:NO];
    }
    return image;
  }

  /**
   * @brief Recursively construct an NSMenu from a null-terminated tray_menu array.
   *
   * @param items Null-terminated array of tray_menu items.
   * @return Newly allocated NSMenu reflecting the item hierarchy.
   */
  NSMenu *build_ns_menu(struct tray_menu *items) {
    NSMenu *menu = [[NSMenu alloc] init];
    [menu setAutoenablesItems:NO];
    if (!items) {
      return menu;
    }

    for (struct tray_menu *m = items; m->text != nullptr; ++m) {
      if (std::strcmp(m->text, "-") == 0) {
        [menu addItem:[NSMenuItem separatorItem]];
        continue;
      }

      NSString *title = [NSString stringWithUTF8String:m->text] ?: @"";
      NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title action:nil keyEquivalent:@""];
      [item setEnabled:(m->disabled == 0)];

      if (m->checkbox) {
        [item setState:(m->checked ? NSControlStateValueOn : NSControlStateValueOff)];
      }

      if (m->submenu) {
        [item setSubmenu:build_ns_menu(m->submenu)];
      } else if (m->cb) {
        [item setTarget:g_delegate];
        [item setAction:@selector(menuItemClicked:)];
        [item setRepresentedObject:[NSValue valueWithPointer:m]];
      }

      [menu addItem:item];
    }
    return menu;
  }

  /**
   * @brief Post a macOS user notification if running inside an app bundle.
   *
   * @param title Notification title.
   * @param text Notification body text.
   */
  void post_user_notification(const std::string &title, const std::string &text) {
    if (title.empty() && text.empty()) {
      return;
    }
    if (![[NSBundle mainBundle] bundleIdentifier]) {
      return;
    }

    UNUserNotificationCenter *center = [UNUserNotificationCenter currentNotificationCenter];
    [center setDelegate:g_delegate];

    UNMutableNotificationContent *content = [[UNMutableNotificationContent alloc] init];
    content.title = [NSString stringWithUTF8String:title.c_str()] ?: @"";
    content.body = [NSString stringWithUTF8String:text.c_str()] ?: @"";

    UNNotificationRequest *request = [UNNotificationRequest requestWithIdentifier:@"lumax.tray.notification"
                                                                          content:content
                                                                          trigger:nil];
    [center addNotificationRequest:request
             withCompletionHandler:^(NSError *error) {
               if (error) {
                 tray_log(2, [[error localizedDescription] UTF8String]);
               }
             }];
  }

  /**
   * @brief Apply tray icon, tooltip, and menu updates on the main thread.
   *
   * @param icon_path Path to the icon resource.
   * @param tooltip Tooltip string for the status item button.
   * @param menu_items Root menu array.
   */
  void apply_tray_ui(const std::string &icon_path, const std::string &tooltip, struct tray_menu *menu_items) {
    if (!g_status_item) {
      return;
    }

    if (!icon_path.empty()) {
      NSImage *image = load_tray_image(icon_path.c_str());
      if (image) {
        g_status_item.button.image = image;
      }
    }

    if (!tooltip.empty()) {
      g_status_item.button.toolTip = [NSString stringWithUTF8String:tooltip.c_str()];
    }

    g_status_item.menu = build_ns_menu(menu_items);
  }

}  // namespace

@implementation LumaxTrayDelegate

- (void)menuItemClicked:(NSMenuItem *)sender {
  NSValue *val = [sender representedObject];
  auto *item = static_cast<struct tray_menu *>([val pointerValue]);
  if (item && item->cb) {
    item->cb(item);
  }
}

- (void)userNotificationCenter:(UNUserNotificationCenter *)center
       willPresentNotification:(UNNotification *)notification
         withCompletionHandler:(void (^)(UNNotificationPresentationOptions options))completionHandler {
  (void) center;
  (void) notification;
  completionHandler(UNNotificationPresentationOptionBanner | UNNotificationPresentationOptionList);
}

- (void)userNotificationCenter:(UNUserNotificationCenter *)center
didReceiveNotificationResponse:(UNNotificationResponse *)response
         withCompletionHandler:(void (^)(void))completionHandler {
  (void) center;
  (void) response;
  void (*cb)() = nullptr;
  {
    std::scoped_lock lock(g_tray_mutex);
    cb = g_last_notification_cb;
  }
  if (cb) {
    cb();
  }
  completionHandler();
}

@end

extern "C" {

  int tray_init(struct tray *tray) {
    if (!tray) {
      return -1;
    }

    g_should_exit.store(false);
    std::string icon_path = tray->icon ? tray->icon : "";
    std::string tooltip = tray->tooltip ? tray->tooltip : "";
    struct tray_menu *menu_items = tray->menu;

    {
      std::scoped_lock lock(g_tray_mutex);
      g_current_tray = tray;
    }

    auto init_block = ^{
      @autoreleasepool {
        [NSApplication sharedApplication];
        if (!g_delegate) {
          g_delegate = [[LumaxTrayDelegate alloc] init];
        }
        if (!g_status_item) {
          g_status_item = [[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength];
        }
        apply_tray_ui(icon_path, tooltip, menu_items);
        if (![NSApp isRunning]) {
          [NSApp finishLaunching];
        }
      }
    };

    if ([NSThread isMainThread]) {
      init_block();
    } else {
      dispatch_sync(dispatch_get_main_queue(), init_block);
    }

    return 0;
  }

  int tray_loop(const int blocking) {
    if (g_should_exit.load()) {
      return -1;
    }

    @autoreleasepool {
      NSDate *until = blocking ? [NSDate distantFuture] : [NSDate distantPast];
      NSEvent *event = [NSApp nextEventMatchingMask:NSEventMaskAny
                                          untilDate:until
                                             inMode:NSDefaultRunLoopMode
                                            dequeue:YES];
      if (event) {
        [NSApp sendEvent:event];
        [NSApp updateWindows];
      }
    }

    return g_should_exit.load() ? -1 : 0;
  }

  void tray_update(struct tray *tray) {
    if (!tray) {
      return;
    }

    std::string icon_path = tray->icon ? tray->icon : "";
    std::string tooltip = tray->tooltip ? tray->tooltip : "";
    std::string notif_title = tray->notification_title ? tray->notification_title : "";
    std::string notif_text = tray->notification_text ? tray->notification_text : "";
    void (*notif_cb)() = tray->notification_cb;
    struct tray_menu *menu_items = tray->menu;

    {
      std::scoped_lock lock(g_tray_mutex);
      g_current_tray = tray;
      if (!notif_title.empty() || !notif_text.empty()) {
        g_last_notification_cb = notif_cb;
      }
    }

    run_on_main_async(^{
      @autoreleasepool {
        apply_tray_ui(icon_path, tooltip, menu_items);
        post_user_notification(notif_title, notif_text);
      }
    });
  }

  void tray_show_menu(void) {
    run_on_main_async(^{
      @autoreleasepool {
        if (g_status_item && g_status_item.button) {
          [g_status_item.button performClick:nil];
        }
      }
    });
  }

#ifdef TRAY_ENABLE_TEST_HOOKS
  int tray_position_mouse_over_icon(void) {
    __block int result = -1;
    auto block = ^{
      if (!g_status_item || !g_status_item.button || !g_status_item.button.window) {
        return;
      }
      g_saved_mouse_pos = [NSEvent mouseLocation];
      g_has_saved_mouse_pos = true;
      NSRect win_frame = g_status_item.button.window.frame;
      NSRect screen_frame = [[NSScreen mainScreen] frame];
      CGPoint target = CGPointMake(NSMidX(win_frame), screen_frame.size.height - NSMidY(win_frame));
      CGWarpMouseCursorPosition(target);
      result = 0;
    };
    if ([NSThread isMainThread]) {
      block();
    } else {
      dispatch_sync(dispatch_get_main_queue(), block);
    }
    return result;
  }

  int tray_restore_mouse_position(void) {
    if (!g_has_saved_mouse_pos) {
      return -1;
    }
    NSRect screen_frame = [[NSScreen mainScreen] frame];
    CGPoint target = CGPointMake(g_saved_mouse_pos.x, screen_frame.size.height - g_saved_mouse_pos.y);
    CGWarpMouseCursorPosition(target);
    g_has_saved_mouse_pos = false;
    return 0;
  }
#endif

  void tray_simulate_notification_click(void) {
    void (*cb)() = nullptr;
    {
      std::scoped_lock lock(g_tray_mutex);
      cb = g_last_notification_cb;
    }
    if (cb) {
      cb();
    }
  }

  void tray_simulate_menu_item_click(const int index) {
    struct tray *current = nullptr;
    {
      std::scoped_lock lock(g_tray_mutex);
      current = g_current_tray;
    }
    if (!current || !current->menu || index < 0) {
      return;
    }
    int i = 0;
    for (struct tray_menu *m = current->menu; m->text != nullptr; ++m, ++i) {
      if (i == index) {
        if (m->cb && std::strcmp(m->text, "-") != 0 && !m->submenu && !m->disabled) {
          m->cb(m);
        }
        break;
      }
    }
  }

  void tray_exit(void) {
    g_should_exit.store(true);
    run_on_main_async(^{
      @autoreleasepool {
        if (g_status_item) {
          [[NSStatusBar systemStatusBar] removeStatusItem:g_status_item];
          g_status_item = nil;
        }
        NSEvent *wakeup = [NSEvent otherEventWithType:NSEventTypeApplicationDefined
                                             location:NSZeroPoint
                                        modifierFlags:0
                                            timestamp:0
                                         windowNumber:0
                                              context:nil
                                              subtype:0
                                                data1:0
                                                data2:0];
        if (wakeup) {
          [NSApp postEvent:wakeup atStart:NO];
        }
      }
    });
  }

  void tray_set_log_callback(void (*cb)(int level, const char *msg)) {
    g_log_callback = cb;
  }

  void tray_set_app_info(const char *app_name, const char *app_display_name, const char *desktop_name) {
    (void) app_name;
    (void) app_display_name;
    (void) desktop_name;
  }

}  // extern "C"
