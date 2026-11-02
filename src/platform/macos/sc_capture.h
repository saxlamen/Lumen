/**
 * @file src/platform/macos/sc_capture.h
 * @brief Declarations for ScreenCaptureKit-based capture on macOS 12.3+.
 * @details This implementation captures both video AND system audio using ScreenCaptureKit.
 */
#pragma once

#import <AppKit/AppKit.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#import <CoreMedia/CoreMedia.h>

API_AVAILABLE(macos(12.3))
@interface SCCapture : NSObject <SCStreamDelegate, SCStreamOutput>

#define kMaxDisplays 32

@property (nonatomic, assign) CGDirectDisplayID displayID;
@property (nonatomic, assign) int frameRate;
@property (nonatomic, assign) OSType pixelFormat;

/// The dynamic range to capture, held as the raw `SCCaptureDynamicRange` values ScreenCaptureKit
/// defines: 0 is SDR, 1 is the local-display HDR picture and 2 is the canonical Rec.2100 picture. Raw
/// numbers keep this header compiling on deployment targets that predate the enum, and
/// `platf::macos_hdr::capture_dynamic_range_e` names the same three modes. A freshly allocated capture
/// object asks for 0, which is the behaviour this platform has always had.
@property (nonatomic, assign) NSInteger captureDynamicRange;

/// The color space captured frames are tagged with, normally `kCGColorSpaceITUR_2100_PQ`. The dynamic
/// range above is not enough by itself: without an explicit Rec.2100 color space ScreenCaptureKit
/// returns frames tagged with the display's SDR ICC profile, which is a silent failure rather than an
/// error. Measured in section 10.2 of `docs/macos_hdr.md`. This is set once while the capture object is
/// being created and never changes, so the capture path reads it without the state lock.
@property (nonatomic, copy, nullable) NSString *hdrColorSpaceName;
@property (nonatomic, assign) int frameWidth;
@property (nonatomic, assign) int frameHeight;
@property (nonatomic, assign) BOOL captureAudio;
@property (nonatomic, assign) BOOL showsCursor;

@property (nonatomic, strong) SCStream *stream;
@property (nonatomic, strong) SCShareableContent *shareableContent;
@property (nonatomic, strong) dispatch_queue_t videoQueue;
@property (nonatomic, strong) dispatch_queue_t audioQueue;

typedef bool (^VideoFrameCallbackBlock)(CMSampleBufferRef);
typedef void (^AudioSampleCallbackBlock)(CMSampleBufferRef);

@property (nonatomic, copy) VideoFrameCallbackBlock videoCallback;
@property (nonatomic, copy) AudioSampleCallbackBlock audioCallback;
@property (nonatomic, strong) dispatch_semaphore_t captureSignal;
@property (nonatomic, assign) BOOL stopping;

+ (NSArray<NSDictionary *> *)displayNames;
+ (NSString *)getDisplayName:(CGDirectDisplayID)displayID;
+ (BOOL)isAvailable;

- (instancetype)initWithDisplay:(CGDirectDisplayID)displayID
                      frameRate:(int)frameRate
                   captureAudio:(BOOL)captureAudio;

- (void)setFrameWidth:(int)frameWidth frameHeight:(int)frameHeight;

/// Number of ScreenCaptureKit deliveries that carried no image and were not forwarded downstream.
- (NSUInteger)idleSampleBuffersSkipped;
- (dispatch_semaphore_t)captureVideo:(VideoFrameCallbackBlock)videoCallback
                         audioCallback:(AudioSampleCallbackBlock)audioCallback;
- (void)stopCapture;
- (void)updateShowsCursor:(BOOL)showsCursor;

@end
