/**
 * @file src/platform/macos/sc_capture.m
 * @brief ScreenCaptureKit-based capture implementation for macOS 12.3+.
 * @details Captures both video AND system audio using Apple's ScreenCaptureKit API.
 */
#import "sc_capture.h"

// system includes
#import <Block.h>
#import <os/lock.h>

API_AVAILABLE(macos(12.3))
@implementation SCCapture {
  /// Guards the scalar capture settings and the cached callbacks, which are written from
  /// the capture and encoder threads and read on the ScreenCaptureKit sample queues.
  os_unfair_lock _stateLock;

  /// ScreenCaptureKit deliveries that carried no image content and were not forwarded downstream.
  NSUInteger _idleSampleBuffersSkipped;
}

+ (BOOL)isAvailable {
    if (@available(macOS 12.3, *)) {
        return YES;
    }
    return NO;
}

+ (NSArray<NSDictionary *> *)displayNames {
    CGDirectDisplayID displays[kMaxDisplays];
    uint32_t count;
    if (CGGetActiveDisplayList(kMaxDisplays, displays, &count) != kCGErrorSuccess) {
        return [NSArray array];
    }

    NSMutableArray *result = [NSMutableArray array];

    for (uint32_t i = 0; i < count; i++) {
        [result addObject:@{
            @"id": [NSNumber numberWithUnsignedInt:displays[i]],
            @"name": [NSString stringWithFormat:@"%d", displays[i]],
            @"displayName": [self getDisplayName:displays[i]] ?: @"Unknown Display",
        }];
    }

    return [NSArray arrayWithArray:result];
}

+ (NSString *)getDisplayName:(CGDirectDisplayID)displayID {
    for (NSScreen *screen in [NSScreen screens]) {
        if ([screen.deviceDescription[@"NSScreenNumber"] isEqualToNumber:[NSNumber numberWithUnsignedInt:displayID]]) {
            return screen.localizedName;
        }
    }
    return nil;
}

- (instancetype)initWithDisplay:(CGDirectDisplayID)displayID
                      frameRate:(int)frameRate
                   captureAudio:(BOOL)captureAudio {
    self = [super init];
    if (self) {
        CGDisplayModeRef mode = CGDisplayCopyDisplayMode(displayID);

        _stateLock = (os_unfair_lock) OS_UNFAIR_LOCK_INIT;

        self.displayID = displayID;
        self.frameRate = frameRate;
        self.pixelFormat = kCVPixelFormatType_32BGRA;
        self.captureAudio = captureAudio;

        if (mode) {
            self.frameWidth = (int)CGDisplayModeGetPixelWidth(mode);
            self.frameHeight = (int)CGDisplayModeGetPixelHeight(mode);
            CFRelease(mode);
        } else {
            // Virtual displays may not have a CGDisplayMode
            self.frameWidth = (int)CGDisplayPixelsWide(displayID);
            self.frameHeight = (int)CGDisplayPixelsHigh(displayID);
        }

        // Create dispatch queues for video and audio processing
        // Capture delivery is latency critical: a frame that waits behind lower priority work in
        // this queue shows up as end-to-end latency, so the queues match the audio capture thread.
        dispatch_queue_attr_t qos = dispatch_queue_attr_make_with_qos_class(
            DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INTERACTIVE, DISPATCH_QUEUE_PRIORITY_HIGH);
        self.videoQueue = dispatch_queue_create("dev.lizardbyte.sunshine.videoQueue", qos);
        self.audioQueue = dispatch_queue_create("dev.lizardbyte.sunshine.audioQueue", qos);

        // Initialize ScreenCaptureKit
        dispatch_semaphore_t initSemaphore = dispatch_semaphore_create(0);
        __block BOOL initSuccess = NO;

        [SCShareableContent getShareableContentWithCompletionHandler:^(SCShareableContent *content, NSError *error) {
            if (error) {
                NSLog(@"[SCCapture] Failed to get shareable content: %@", error.localizedDescription);
            } else {
                self.shareableContent = content;
                initSuccess = YES;
            }
            dispatch_semaphore_signal(initSemaphore);
        }];

        dispatch_semaphore_wait(initSemaphore, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));

        if (!initSuccess) {
            return nil;
        }
    }
    return self;
}

- (void)dealloc {
    [self stopCapture];
    [super dealloc];
}

- (void)setFrameWidth:(int)frameWidth {
    os_unfair_lock_lock(&_stateLock);
    _frameWidth = frameWidth;
    os_unfair_lock_unlock(&_stateLock);
}

- (void)setFrameHeight:(int)frameHeight {
    os_unfair_lock_lock(&_stateLock);
    _frameHeight = frameHeight;
    os_unfair_lock_unlock(&_stateLock);
}

- (void)setPixelFormat:(OSType)pixelFormat {
    os_unfair_lock_lock(&_stateLock);
    _pixelFormat = pixelFormat;
    os_unfair_lock_unlock(&_stateLock);
}

- (void)setStopping:(BOOL)stopping {
    os_unfair_lock_lock(&_stateLock);
    _stopping = stopping;
    os_unfair_lock_unlock(&_stateLock);
}

- (void)setFrameWidth:(int)frameWidth frameHeight:(int)frameHeight {
    // Write the pair as one update: nv12_zero_device calls this from the encoder thread while the
    // capture thread may be building an SCStreamConfiguration.
    os_unfair_lock_lock(&_stateLock);
    _frameWidth = frameWidth;
    _frameHeight = frameHeight;
    os_unfair_lock_unlock(&_stateLock);
}

- (NSUInteger)idleSampleBuffersSkipped {
    os_unfair_lock_lock(&_stateLock);
    NSUInteger skipped = _idleSampleBuffersSkipped;
    os_unfair_lock_unlock(&_stateLock);
    return skipped;
}

- (SCDisplay *)findDisplayWithID:(CGDirectDisplayID)displayID {
    for (SCDisplay *display in self.shareableContent.displays) {
        if (display.displayID == displayID) {
            return display;
        }
    }
    return nil;
}

- (SCDisplay *)findDisplayWithIDRetrying:(CGDirectDisplayID)displayID {
    // First try with cached content
    SCDisplay *display = [self findDisplayWithID:displayID];
    if (display) return display;

    // Virtual displays may not appear immediately — retry with fresh content
    for (int attempt = 1; attempt <= 3; attempt++) {
        NSLog(@"[SCCapture] Display %u not found in SCShareableContent, refreshing (attempt %d/3)", displayID, attempt);
        [NSThread sleepForTimeInterval:1.0];

        dispatch_semaphore_t sem = dispatch_semaphore_create(0);
        __block BOOL success = NO;

        [SCShareableContent getShareableContentWithCompletionHandler:^(SCShareableContent *content, NSError *error) {
            if (!error && content) {
                self.shareableContent = content;
                success = YES;
            }
            dispatch_semaphore_signal(sem);
        }];

        dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));

        if (success) {
            display = [self findDisplayWithID:displayID];
            if (display) {
                NSLog(@"[SCCapture] Found display %u after refresh", displayID);
                return display;
            }
        }
    }

    return nil;
}

- (dispatch_semaphore_t)captureVideo:(VideoFrameCallbackBlock)videoCallback
                       audioCallback:(AudioSampleCallbackBlock)audioCallback {
    @synchronized(self) {
        // Stop any existing capture before starting a new one
        if (self.stream) {
            dispatch_semaphore_t stopSem = dispatch_semaphore_create(0);
            [self.stream stopCaptureWithCompletionHandler:^(NSError *error) {
                dispatch_semaphore_signal(stopSem);
            }];
            dispatch_semaphore_wait(stopSem, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC));
            self.stream = nil;
        }

        self.stopping = NO;  // Reset stopping flag for new capture cycle
        self.videoCallback = videoCallback;
        self.audioCallback = audioCallback;
        self.captureSignal = dispatch_semaphore_create(0);

        SCDisplay *display = [self findDisplayWithIDRetrying:self.displayID];
        if (!display) {
            NSLog(@"[SCCapture] Display not found after retries: %u", self.displayID);
            return nil;
        }

        // Create content filter for the display
        SCContentFilter *filter = [[SCContentFilter alloc] initWithDisplay:display excludingWindows:@[]];

        // Configure the stream
        SCStreamConfiguration *config = [[SCStreamConfiguration alloc] init];

        // Snapshot the settings as one consistent set: nv12_zero_device can change the capture
        // size/format from the encoder thread while the capture thread starts a new stream.
        int captureWidth;
        int captureHeight;
        int captureFrameRate;
        OSType capturePixelFormat;
        BOOL captureShowsCursor;

        os_unfair_lock_lock(&_stateLock);
        captureWidth = _frameWidth;
        captureHeight = _frameHeight;
        captureFrameRate = _frameRate;
        capturePixelFormat = _pixelFormat;
        captureShowsCursor = _showsCursor;
        os_unfair_lock_unlock(&_stateLock);

        config.width = captureWidth;
        config.height = captureHeight;
        config.minimumFrameInterval = CMTimeMake(1, captureFrameRate);
        config.pixelFormat = capturePixelFormat;
        // The capture thread keeps a pool of images plus frames in flight through the encoder.
        // A queue shallower than that lets ScreenCaptureKit recycle buffers that are still
        // referenced, so the encoder would read recycled pixels.
        config.queueDepth = 16;
        config.showsCursor = captureShowsCursor;

        // Enable audio capture - this is the key feature!
        if (self.captureAudio) {
            config.capturesAudio = YES;
            config.excludesCurrentProcessAudio = YES;  // Don't capture our own audio
            config.sampleRate = 48000;
            config.channelCount = 2;
        }

        // Create and configure the stream
        NSError *error = nil;
        self.stream = [[SCStream alloc] initWithFilter:filter configuration:config delegate:self];

        if (!self.stream) {
            NSLog(@"[SCCapture] Failed to create SCStream");
            return nil;
        }

        // Add video output
        if (![self.stream addStreamOutput:self type:SCStreamOutputTypeScreen sampleHandlerQueue:self.videoQueue error:&error]) {
            NSLog(@"[SCCapture] Failed to add video output: %@", error.localizedDescription);
            return nil;
        }

        // Add audio output if enabled
        if (self.captureAudio) {
            if (![self.stream addStreamOutput:self type:SCStreamOutputTypeAudio sampleHandlerQueue:self.audioQueue error:&error]) {
                NSLog(@"[SCCapture] Failed to add audio output: %@", error.localizedDescription);
                // Continue without audio - video is more important
            } else {
                NSLog(@"[SCCapture] System audio capture enabled!");
            }
        }

        // Start capture
        dispatch_semaphore_t startSemaphore = dispatch_semaphore_create(0);
        __block BOOL startSuccess = NO;

        [self.stream startCaptureWithCompletionHandler:^(NSError *error) {
            if (error) {
                NSLog(@"[SCCapture] Failed to start capture: %@", error.localizedDescription);
            } else {
                NSLog(@"[SCCapture] Capture started successfully with%@ audio", self.captureAudio ? @"" : @"out");
                startSuccess = YES;
            }
            dispatch_semaphore_signal(startSemaphore);
        }];

        dispatch_semaphore_wait(startSemaphore, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));

        if (!startSuccess) {
            return nil;
        }

        return self.captureSignal;
    }
}

- (void)stopCapture {
    @synchronized(self) {
        // Reject queued frame deliveries before tearing anything down
        self.stopping = YES;

        if (self.stream) {
            dispatch_semaphore_t stopSemaphore = dispatch_semaphore_create(0);

            [self.stream stopCaptureWithCompletionHandler:^(NSError *error) {
                if (error) {
                    NSLog(@"[SCCapture] Error stopping capture: %@", error.localizedDescription);
                }
                dispatch_semaphore_signal(stopSemaphore);
            }];

            dispatch_semaphore_wait(stopSemaphore, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC));
            self.stream = nil;
        }

        if (self.captureSignal) {
            dispatch_semaphore_signal(self.captureSignal);
            self.captureSignal = nil;
        }

        self.videoCallback = nil;
        self.audioCallback = nil;
    }
}

- (void)updateShowsCursor:(BOOL)showsCursor {
    @synchronized(self) {
        os_unfair_lock_lock(&_stateLock);
        _showsCursor = showsCursor;
        os_unfair_lock_unlock(&_stateLock);
        // If stream is already running, we need to restart it to apply the new setting
        if (self.stream) {
            // Save current callback blocks
            VideoFrameCallbackBlock vidCb = self.videoCallback;
            AudioSampleCallbackBlock audCb = self.audioCallback;

            // Stop current capture
            dispatch_semaphore_t stopSem = dispatch_semaphore_create(0);
            [self.stream stopCaptureWithCompletionHandler:^(NSError *error) {
                if (error) {
                    NSLog(@"[SCCapture] Error stopping capture for cursor update: %@", error.localizedDescription);
                }
                dispatch_semaphore_signal(stopSem);
            }];
            dispatch_semaphore_wait(stopSem, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC));
            self.stream = nil;

            // Restart with same callbacks
            if (vidCb) {
                [self captureVideo:vidCb audioCallback:audCb];
            }
        }
    }
}

#pragma mark - SCStreamDelegate

- (void)stream:(SCStream *)stream didStopWithError:(NSError *)error {
    NSLog(@"[SCCapture] Stream stopped with error: %@", error.localizedDescription);
    if (self.captureSignal) {
        dispatch_semaphore_signal(self.captureSignal);
    }
}

#pragma mark - SCStreamOutput

- (void)stream:(SCStream *)stream
    didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
                   ofType:(SCStreamOutputType)type {

    if (type == SCStreamOutputTypeScreen) {
        CVPixelBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
        if (!pixelBuffer) {
            // ScreenCaptureKit emits status deliveries with no image content while the display is
            // idle. video::captureThread() already maintains the minimum frame rate by re-encoding
            // the previous frame, so forwarding the last valid sample here only pushed the same
            // IOSurface through the capture pool a second time.
            os_unfair_lock_lock(&_stateLock);
            ++_idleSampleBuffersSkipped;
            os_unfair_lock_unlock(&_stateLock);
            return;
        }

        // Take our own reference to the callback under the lock, then deliver outside of it:
        // stopCapture can be called from another thread at any point and releases the callback.
        VideoFrameCallbackBlock callback = nil;
        CMSampleBufferRef delivered = NULL;

        @synchronized(self) {
            if (!self.stopping && self.videoCallback) {
                callback = Block_copy(self.videoCallback);
                delivered = (CMSampleBufferRef) CFRetain(sampleBuffer);
            }
        }

        if (!callback || !delivered) {
            return;
        }

        bool continueCapture = callback(delivered) ? true : false;

        CFRelease(delivered);
        Block_release(callback);

        if (!continueCapture) {
            self.stopping = YES;
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                [self stopCapture];
            });
        }
    } else if (type == SCStreamOutputTypeAudio) {
        AudioSampleCallbackBlock callback = nil;

        @synchronized(self) {
            if (!self.stopping && self.audioCallback) {
                callback = Block_copy(self.audioCallback);
            }
        }

        if (!callback) {
            return;
        }

        callback(sampleBuffer);
        Block_release(callback);
    }
}

@end
