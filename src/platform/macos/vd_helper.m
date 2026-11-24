/**
 * @file src/platform/macos/vd_helper.m
 * @brief Helper process to create and hold a CGVirtualDisplay.
 *
 * Spawned by Sunshine to create virtual displays in a clean process context.
 * Usage: vd_helper <width> <height> <fps>
 * Outputs: displayID on stdout (or "0" on failure)
 * Stays alive holding the display until SIGTERM is received.
 *
 * CGVirtualDisplay creates the display object, then we:
 *   1. SLSConfigureDisplayEnabled activates it in WindowServer's display list
 *   2. CGConfigureDisplayMirrorOfDisplay(kCGNullDirectDisplay) forces extend mode
 *      (macOS may auto-mirror new displays, hiding them from CGGetActiveDisplayList)
 * Compiled with ARC (-fobjc-arc).
 */
#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <CoreGraphics/CoreGraphics.h>
#include <signal.h>
#include <unistd.h>

// Private CGVirtualDisplay API interface declarations (macOS 14+)
@interface CGVirtualDisplayMode : NSObject
- (instancetype)initWithWidth:(unsigned int)width height:(unsigned int)height refreshRate:(double)refreshRate;
- (instancetype)initWithWidth:(unsigned int)width
                       height:(unsigned int)height
                  refreshRate:(double)refreshRate
             transferFunction:(unsigned int)transferFunction;
@end

@interface CGVirtualDisplaySettings : NSObject
@property (nonatomic) unsigned int hiDPI;
@property (retain, nonatomic) NSArray *modes;
@end

@interface CGVirtualDisplayDescriptor : NSObject
@property (retain, nonatomic) NSString *name;
@property (nonatomic) unsigned int vendorID;
@property (nonatomic) unsigned int productID;
@property (nonatomic) unsigned int serialNum;
@property (nonatomic) unsigned int maxPixelsWide;
@property (nonatomic) unsigned int maxPixelsHigh;
@property (nonatomic) CGSize sizeInMillimeters;
@property (nonatomic) CGPoint whitePoint;
@property (nonatomic) CGPoint redPrimary;
@property (nonatomic) CGPoint greenPrimary;
@property (nonatomic) CGPoint bluePrimary;
@property (retain, nonatomic) dispatch_queue_t queue;
@property (copy, nonatomic) void (^terminationHandler)(id, id);
- (void)setDispatchQueue:(dispatch_queue_t)queue;
@end

@interface CGVirtualDisplay : NSObject
@property (readonly, nonatomic) unsigned int displayID;
- (instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)descriptor;
- (BOOL)applySettings:(CGVirtualDisplaySettings *)settings;
@end

// SkyLight private C functions for display configuration (linked directly)
extern CGError SLSBeginDisplayConfiguration(CGDisplayConfigRef *);
extern CGError SLSConfigureDisplayEnabled(CGDisplayConfigRef, CGDirectDisplayID, bool);
extern CGError SLSConfigureDisplayOrigin(CGDisplayConfigRef, CGDirectDisplayID, int32_t, int32_t);
extern CGError SLSCompleteDisplayConfiguration(CGDisplayConfigRef, CGConfigureOption, uint32_t);

// Static storage to keep objects alive (ARC retains static references)
static CGVirtualDisplay *keepAlive = nil;
static CGVirtualDisplayDescriptor *keepDesc = nil;

static volatile sig_atomic_t shouldExit = 0;
static volatile sig_atomic_t pendingMainAction = 0; // 1 = make virtual main, 2 = restore original main

static void handle_signal(int sig) {
  (void)sig;
  shouldExit = 1;
  dispatch_async(dispatch_get_main_queue(), ^{
    CFRunLoopStop(CFRunLoopGetMain());
  });
}

static void handle_main_signal(int sig) {
  pendingMainAction = (sig == SIGUSR1) ? 1 : 2;
  dispatch_async(dispatch_get_main_queue(), ^{
    CFRunLoopStop(CFRunLoopGetMain());
  });
}

static BOOL checkDisplayInList(uint32_t targetID, uint32_t *outCount) {
  CGDirectDisplayID activeDisplays[32];
  uint32_t displayCount = 0;
  if (CGGetActiveDisplayList(32, activeDisplays, &displayCount) == kCGErrorSuccess) {
    if (outCount) *outCount = displayCount;
    for (uint32_t i = 0; i < displayCount; i++) {
      if (activeDisplays[i] == targetID) return YES;
    }
  }
  return NO;
}

/**
 * @brief Position the virtual display at origin (0, 0) so macOS makes it the main display.
 *
 * @param virtualID CoreGraphics display ID of the virtual display.
 * @param virtualWidth Width of the virtual display used to offset the previous main display.
 */
static void makeVirtualDisplayMain(CGDirectDisplayID virtualID, int virtualWidth) {
  CGDirectDisplayID prevMain = CGMainDisplayID();
  if (prevMain == virtualID) {
    return;
  }
  CGDisplayConfigRef config = NULL;
  CGError err = CGBeginDisplayConfiguration(&config);
  if (err != kCGErrorSuccess || !config) {
    fprintf(stderr, "[vd_helper] CGBeginDisplayConfiguration for main switch failed: %d\n", err);
    return;
  }
  CGConfigureDisplayOrigin(config, virtualID, 0, 0);
  if (prevMain != 0 && prevMain != virtualID) {
    CGConfigureDisplayOrigin(config, prevMain, (int32_t)virtualWidth, 0);
  }
  err = CGCompleteDisplayConfiguration(config, kCGConfigureForSession);
  fprintf(stderr, "[vd_helper] Set virtual display %u as main (prev=%u): %d\n", virtualID, prevMain, err);
}

/**
 * @brief Restore the original display to origin (0, 0) when streaming pauses.
 *
 * @param virtualID CoreGraphics display ID of the virtual display.
 * @param originalMainID CoreGraphics display ID of the original main display.
 */
static void restoreOriginalMain(CGDirectDisplayID virtualID, CGDirectDisplayID originalMainID) {
  if (originalMainID == 0 || originalMainID == virtualID || !CGDisplayIsOnline(originalMainID)) {
    return;
  }
  if (CGMainDisplayID() == originalMainID) {
    return;
  }
  CGDisplayConfigRef config = NULL;
  CGError err = CGBeginDisplayConfiguration(&config);
  if (err != kCGErrorSuccess || !config) {
    fprintf(stderr, "[vd_helper] CGBeginDisplayConfiguration for restore failed: %d\n", err);
    return;
  }
  size_t origWidth = CGDisplayPixelsWide(originalMainID);
  CGConfigureDisplayOrigin(config, originalMainID, 0, 0);
  CGConfigureDisplayOrigin(config, virtualID, (int32_t)origWidth, 0);
  err = CGCompleteDisplayConfiguration(config, kCGConfigureForSession);
  fprintf(stderr, "[vd_helper] Restored original main display %u: %d\n", originalMainID, err);
}

/**
 * Force the virtual display into "extend" mode (not mirrored) and make it the
 * main display at origin (0, 0) so macOS input injection targets it directly.
 */
static void forceExtendMode(CGDirectDisplayID virtualID, int virtualWidth) {
  CGDirectDisplayID mainDisplay = CGMainDisplayID();

  // Check if main display is now mirroring our virtual display
  CGDirectDisplayID mainMirrorTarget = CGDisplayMirrorsDisplay(mainDisplay);
  if (mainMirrorTarget == virtualID) {
    fprintf(stderr, "[vd_helper] Main display is mirroring us (%u), un-mirroring main\n", virtualID);
    CGDisplayConfigRef config = NULL;
    CGBeginDisplayConfiguration(&config);
    if (config) {
      CGConfigureDisplayMirrorOfDisplay(config, mainMirrorTarget, kCGNullDirectDisplay);
      CGCompleteDisplayConfiguration(config, kCGConfigureForSession);
    }
  }

  // Check if our display is in a mirror set
  if (CGDisplayIsInMirrorSet(virtualID)) {
    fprintf(stderr, "[vd_helper] Display %u is in mirror set, un-mirroring\n", virtualID);
    CGDisplayConfigRef config = NULL;
    CGBeginDisplayConfiguration(&config);
    if (config) {
      CGConfigureDisplayMirrorOfDisplay(config, virtualID, kCGNullDirectDisplay);
      CGCompleteDisplayConfiguration(config, kCGConfigureForSession);
    }
  }

  // Also check if virtual display is mirroring main
  CGDirectDisplayID virtualMirrorTarget = CGDisplayMirrorsDisplay(virtualID);
  if (virtualMirrorTarget != 0) {
    fprintf(stderr, "[vd_helper] Display %u mirrors %u, un-mirroring\n", virtualID, virtualMirrorTarget);
    CGDisplayConfigRef config = NULL;
    CGBeginDisplayConfiguration(&config);
    if (config) {
      CGConfigureDisplayMirrorOfDisplay(config, virtualID, kCGNullDirectDisplay);
      CGCompleteDisplayConfiguration(config, kCGConfigureForSession);
    }
  }

  // Make the virtual display the main display at (0, 0) and shift previous main to the right.
  {
    CGDisplayConfigRef config = NULL;
    CGBeginDisplayConfiguration(&config);
    if (config) {
      CGConfigureDisplayOrigin(config, virtualID, 0, 0);
      if (mainDisplay != 0 && mainDisplay != virtualID) {
        CGConfigureDisplayOrigin(config, mainDisplay, (int32_t)virtualWidth, 0);
      }
      CGCompleteDisplayConfiguration(config, kCGConfigureForSession);
    }
  }
}

/**
 * @brief Create a CGVirtualDisplayMode, optionally requesting HDR/EDR transfer function.
 *
 * @param width Pixel width of the display mode.
 * @param height Pixel height of the display mode.
 * @param fps Refresh rate in Hz.
 * @param tryHDR Whether to request the HDR/EDR transfer function (transferFunction = 1).
 * @return A configured CGVirtualDisplayMode instance, or nil on failure.
 */
static CGVirtualDisplayMode *createDisplayMode(unsigned int width, unsigned int height, double fps, BOOL tryHDR) {
  CGVirtualDisplayMode *mode = nil;
  if (tryHDR) {
    mode = [[CGVirtualDisplayMode alloc] initWithWidth:width height:height refreshRate:fps transferFunction:1];
  }
  if (!mode) {
    mode = [[CGVirtualDisplayMode alloc] initWithWidth:width height:height refreshRate:fps];
  }
  return mode;
}

/**
 * @brief Build the list of CGVirtualDisplayMode entries for the virtual display.
 *
 * Always includes the requested native mode and its half-resolution HiDPI pair.
 * For 4:3 streams, also registers mainstream 4:3 resolutions and their 2x
 * backing stores so macOS System Settings offers crisp HiDPI scaling options.
 *
 * @param width Requested pixel width.
 * @param height Requested pixel height.
 * @param fps Refresh rate in Hz.
 * @param tryHDR Whether to request the HDR/EDR transfer function.
 * @return Non-empty array of CGVirtualDisplayMode objects, or nil if native mode failed.
 */
static NSArray<CGVirtualDisplayMode *> *buildDisplayModes(int width, int height, double fps, BOOL tryHDR) {
  CGVirtualDisplayMode *nativeMode = createDisplayMode((unsigned int)width, (unsigned int)height, fps, tryHDR);
  if (!nativeMode) {
    return nil;
  }

  NSMutableArray<CGVirtualDisplayMode *> *modes = [NSMutableArray arrayWithObject:nativeMode];
  NSMutableSet<NSString *> *seen = [NSMutableSet setWithObject:[NSString stringWithFormat:@"%dx%d", width, height]];

  void (^addIfNew)(int, int) = ^(int w, int h) {
    if (w <= 0 || h <= 0) {
      return;
    }
    NSString *key = [NSString stringWithFormat:@"%dx%d", w, h];
    if ([seen containsObject:key]) {
      return;
    }
    CGVirtualDisplayMode *m = createDisplayMode((unsigned int)w, (unsigned int)h, fps, tryHDR);
    if (m) {
      [seen addObject:key];
      [modes addObject:m];
    }
  };

  addIfNew(width / 2, height / 2);

  // Register mainstream 4:3 resolutions (and 2x backing stores for HiDPI) when 4:3 is requested
  if (abs(width * 3 - height * 4) <= 4) {
    static const int kFourThreeModes[][2] = {
      {800, 600},
      {1024, 768},
      {1152, 864},
      {1280, 960},
      {1400, 1050},
      {1440, 1080},
      {1600, 1200},
      {1920, 1440},
      {2048, 1536},
      {2304, 1728},
      {2560, 1920},
      {2800, 2100},
      {2880, 2160},
      {3200, 2400},
    };
    for (size_t i = 0; i < sizeof(kFourThreeModes) / sizeof(kFourThreeModes[0]); i++) {
      addIfNew(kFourThreeModes[i][0], kFourThreeModes[i][1]);
    }
  }

  return modes;
}

int main(int argc, const char *argv[]) {
  // Close all inherited file descriptors (especially parent listening sockets)
  // so vd_helper never holds Lumax's network ports across restarts.
  long openMax = sysconf(_SC_OPEN_MAX);
  if (openMax <= 0 || openMax > 65536) {
    openMax = 4096;
  }
  for (int fd = STDERR_FILENO + 1; fd < (int)openMax; fd++) {
    close(fd);
  }

  @autoreleasepool {
    if (argc != 4) {
      fprintf(stdout, "0\n");
      fflush(stdout);
      return 1;
    }

    int width = atoi(argv[1]);
    int height = atoi(argv[2]);
    int fps = atoi(argv[3]);

    if (width <= 0 || height <= 0 || fps <= 0) {
      fprintf(stdout, "0\n");
      fflush(stdout);
      return 1;
    }

    // Runtime availability check
    if (!NSClassFromString(@"CGVirtualDisplay")) {
      fprintf(stderr, "[vd_helper] CGVirtualDisplay API not available\n");
      fprintf(stdout, "0\n");
      fflush(stdout);
      return 1;
    }

    // Initialize NSApplication
    [NSApplication sharedApplication];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];

    // Set up signal handlers
    signal(SIGTERM, handle_signal);
    signal(SIGINT, handle_signal);
    signal(SIGHUP, handle_signal);
    signal(SIGUSR1, handle_main_signal);
    signal(SIGUSR2, handle_main_signal);

    CGDirectDisplayID originalMainID = CGMainDisplayID();

    // Create display directly on main thread
    CGVirtualDisplayDescriptor *desc = [[CGVirtualDisplayDescriptor alloc] init];
    desc.name = @"Sunshine Virtual Display";
    desc.vendorID = 0xF0F0;
    desc.productID = 0x5678;
    desc.serialNum = arc4random();
    const BOOL isFourThree = (abs(width * 3 - height * 4) <= 4);
    desc.maxPixelsWide = isFourThree ? MAX((unsigned int)width, 3200u) : (unsigned int)width;
    desc.maxPixelsHigh = isFourThree ? MAX((unsigned int)height, 2400u) : (unsigned int)height;
    // Fixed 27" monitor physical size — do NOT scale linearly with resolution.
    // WindowServer rejects displays with unreasonably large physical dimensions.
    desc.sizeInMillimeters = CGSizeMake(597, 336);
    desc.whitePoint = CGPointMake(0.3127, 0.3290);
    BOOL supportsTransferFunction = [CGVirtualDisplayMode instancesRespondToSelector:
      @selector(initWithWidth:height:refreshRate:transferFunction:)];
    if (supportsTransferFunction) {
      // BT.2020 primaries for HDR/EDR-capable virtual display
      desc.redPrimary = CGPointMake(0.708, 0.292);
      desc.greenPrimary = CGPointMake(0.170, 0.797);
      desc.bluePrimary = CGPointMake(0.131, 0.046);
    } else {
      desc.redPrimary = CGPointMake(0.64, 0.33);
      desc.greenPrimary = CGPointMake(0.30, 0.60);
      desc.bluePrimary = CGPointMake(0.15, 0.06);
    }
    [desc setDispatchQueue:dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0)];
    desc.terminationHandler = ^(id s, id d) {
      fprintf(stderr, "[vd_helper] Virtual display terminated by system\n");
    };

    NSArray<CGVirtualDisplayMode *> *modes = buildDisplayModes(width, height, (double)fps, supportsTransferFunction);
    if (!modes) {
      fprintf(stderr, "[vd_helper] Failed to create CGVirtualDisplayMode\n");
      fprintf(stdout, "0\n");
      fflush(stdout);
      return 1;
    }

    CGVirtualDisplaySettings *settings = [[CGVirtualDisplaySettings alloc] init];
    settings.hiDPI = 1;
    settings.modes = modes;

    CGVirtualDisplay *display = [[CGVirtualDisplay alloc] initWithDescriptor:desc];
    if (!display) {
      fprintf(stderr, "[vd_helper] initWithDescriptor returned nil (trying background thread)\n");

      // Fallback: try on background thread
      __block CGVirtualDisplay *bgDisplay = nil;
      dispatch_semaphore_t sem = dispatch_semaphore_create(0);
      dispatch_async(dispatch_get_global_queue(0, 0), ^{
        bgDisplay = [[CGVirtualDisplay alloc] initWithDescriptor:desc];
        if (bgDisplay) [bgDisplay applySettings:settings];
        dispatch_semaphore_signal(sem);
      });
      dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 5LL * NSEC_PER_SEC));
      display = bgDisplay;
    } else {
      [display applySettings:settings];
    }

    if (!display || display.displayID == 0) {
      fprintf(stderr, "[vd_helper] Failed to create virtual display\n");
      fprintf(stdout, "0\n");
      fflush(stdout);
      return 1;
    }

    keepAlive = display;
    keepDesc = desc;
    uint32_t resultID = display.displayID;

    fprintf(stderr, "[vd_helper] Display %u created, activating...\n", resultID);

    // Step 1: Activate display via SkyLight SLSConfigureDisplayEnabled and make it main (0, 0)
    {
      CGDisplayConfigRef cgConfig = NULL;
      CGError err = SLSBeginDisplayConfiguration(&cgConfig);
      fprintf(stderr, "[vd_helper] SLSBeginDisplayConfiguration: %d\n", err);
      if (err == kCGErrorSuccess && cgConfig) {
        err = SLSConfigureDisplayEnabled(cgConfig, resultID, true);
        fprintf(stderr, "[vd_helper] SLSConfigureDisplayEnabled(%u, true): %d\n", resultID, err);
        CGDirectDisplayID prevMain = CGMainDisplayID();
        SLSConfigureDisplayOrigin(cgConfig, resultID, 0, 0);
        if (prevMain != 0 && prevMain != resultID) {
          SLSConfigureDisplayOrigin(cgConfig, prevMain, (int32_t)width, 0);
        }
        CGError completeErr = SLSCompleteDisplayConfiguration(cgConfig, kCGConfigureForSession, 0);
        fprintf(stderr, "[vd_helper] SLSCompleteDisplayConfiguration: %d\n", completeErr);
      }
    }

    // Wait for WindowServer to process the display
    usleep(500000); // 500ms

    // Step 2: Force extend mode (un-mirror) if needed
    if (CGDisplayIsInMirrorSet(resultID) || CGDisplayMirrorsDisplay(resultID) != 0) {
      fprintf(stderr, "[vd_helper] Mirror detected, forcing extend mode\n");
      forceExtendMode(resultID, width);
    }

    // Step 3: Switch to native resolution (1x scale) mode.
    // The display starts as retina 2x (logical=half, pixel=full).
    // For streaming, we want native 1x (logical=full, pixel=full) to avoid
    // compositor overhead that causes latency and FPS drops.
    {
      NSDictionary *opts = @{(NSString *)kCGDisplayShowDuplicateLowResolutionModes: @YES};
      CFArrayRef allModes = CGDisplayCopyAllDisplayModes(resultID, (CFDictionaryRef)opts);
      if (allModes) {
        CGDisplayModeRef nativeMode = NULL;
        CFIndex modeCount = CFArrayGetCount(allModes);
        for (CFIndex i = 0; i < modeCount; i++) {
          CGDisplayModeRef m = (CGDisplayModeRef)CFArrayGetValueAtIndex(allModes, i);
          size_t lw = CGDisplayModeGetWidth(m);
          size_t lh = CGDisplayModeGetHeight(m);
          size_t pw = CGDisplayModeGetPixelWidth(m);
          size_t ph = CGDisplayModeGetPixelHeight(m);
          // Find the 1x native mode matching our requested resolution
          if ((int)lw == width && (int)lh == height && pw == lw && ph == lh) {
            nativeMode = m;
            break;
          }
        }
        if (nativeMode) {
          CGError modeErr = CGDisplaySetDisplayMode(resultID, nativeMode, NULL);
          fprintf(stderr, "[vd_helper] Switched to native %dx%d (1x scale): %d\n", width, height, modeErr);
        } else {
          fprintf(stderr, "[vd_helper] Native %dx%d mode not found, staying at retina 2x\n", width, height);
        }
        CFRelease(allModes);
      }
    }

    // Wait for mode switch to take effect
    usleep(500000); // 500ms

    // Ensure virtual display is at (0, 0) so it becomes CGMainDisplayID()
    makeVirtualDisplayMain(resultID, width);
    usleep(300000); // 300ms

    // Step 3: If still not visible, try again after a longer wait
    uint32_t count = 0;
    BOOL found = checkDisplayInList(resultID, &count);
    if (!found) {
      fprintf(stderr, "[vd_helper] Display %u not found after first attempt, retrying...\n", resultID);
      sleep(1);
      // Check mirror state again
      fprintf(stderr, "[vd_helper] Mirror state (retry): inMirrorSet=%d, mirrorsDisplay=%u\n",
              CGDisplayIsInMirrorSet(resultID), CGDisplayMirrorsDisplay(resultID));
      forceExtendMode(resultID, width);
      usleep(500000);
      found = checkDisplayInList(resultID, &count);
    }

    fprintf(stderr, "[vd_helper] Display %u (%dx%d@%dHz) - %s in active list (%u total)\n",
            resultID, width, height, fps, found ? "FOUND" : "NOT found", count);

    // Log all active displays for debugging
    {
      CGDirectDisplayID activeDisplays[32];
      uint32_t dCount = 0;
      CGGetActiveDisplayList(32, activeDisplays, &dCount);
      for (uint32_t i = 0; i < dCount; i++) {
        fprintf(stderr, "[vd_helper]   active[%u] = %u (online=%d, active=%d, mirror=%u)\n",
                i, activeDisplays[i],
                CGDisplayIsOnline(activeDisplays[i]),
                CGDisplayIsActive(activeDisplays[i]),
                CGDisplayMirrorsDisplay(activeDisplays[i]));
      }
      // Also check our display specifically
      fprintf(stderr, "[vd_helper]   ours[%u]: online=%d, active=%d, inMirror=%d, mirrors=%u\n",
              resultID,
              CGDisplayIsOnline(resultID),
              CGDisplayIsActive(resultID),
              CGDisplayIsInMirrorSet(resultID),
              CGDisplayMirrorsDisplay(resultID));
    }

    fprintf(stdout, "%u\n", resultID);
    fflush(stdout);

    // Keep alive via CFRunLoop and handle main-display switch signals
    while (!shouldExit) {
      CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.25, false);
      if (getppid() == 1) {
        fprintf(stderr, "[vd_helper] Parent process exited, shutting down\n");
        shouldExit = 1;
        break;
      }
      sig_atomic_t action = pendingMainAction;
      if (action != 0) {
        pendingMainAction = 0;
        if (action == 1) {
          makeVirtualDisplayMain(resultID, width);
        } else if (action == 2) {
          restoreOriginalMain(resultID, originalMainID);
        }
      }
    }

    fprintf(stderr, "[vd_helper] Shutting down, releasing display %u\n", resultID);
    keepAlive = nil;
    keepDesc = nil;
  }
  return 0;
}
