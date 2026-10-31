// vtprobe.m - standalone VideoToolbox encoder-window probe.
//
// Measures how many frames VideoToolbox holds in flight (the "compression window", the value
// Lumen reports as `D` in "Video: encoder output latency") for a given set of VTSession
// properties, without involving Lumen or FFmpeg.
//
// Each trial submits frames at the display cadence from IOSurface-backed pixel buffers, using
// PTS = CMTimeMake(index, fps). Because we control the time base, the output callback can map a
// completed sample back to its submission record and derive both window depth and latency.
//
// Build:
//   clang -fobjc-arc -framework Foundation -framework CoreMedia -framework CoreVideo \
//         -framework VideoToolbox vtprobe.m -o vtprobe
// Run:
//   ./vtprobe --codec hevc --w 2560 --h 1920 --fps 60 --frames 120 \
//             --delay -2,-1,1,0 --inflight 0,1,2 --bitrate 36588000 [--noise] [--tenbit]
//   delay: -2 leave MaxFrameDelayCount unset (Apple default), -1 unlimited, N hold at most N.

#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>
#import <VideoToolbox/VideoToolbox.h>

#import <os/lock.h>
#import <time.h>

/// One measurement target.
struct trial_config {
  CMVideoCodecType codec;  ///< kCMVideoCodecType_H264 or kCMVideoCodecType_HEVC.
  OSType pix_fmt;  ///< Pixel format requested through the source image buffer attributes.
  int width;  ///< Frame width in pixels.
  int height;  ///< Frame height in pixels.
  int fps;  ///< Submission cadence.
  int frames;  ///< Frames to submit.
  int bitrate;  ///< Average bitrate in bit/s.
  int delay_mode;  ///< -2 = leave MaxFrameDelayCount unset, otherwise the value to set.
  int inflight_cap;  ///< 0 = submit without waiting, otherwise max frames held by us.
  bool noise;  ///< Fill luma with pseudo noise instead of a moving ramp.
};

/// Submission timestamps, indexed by frame number.
struct submit_record {
  uint64_t submit_ns;  ///< Monotonic host time the frame was handed to VideoToolbox.
};

/// Results collected by the output callback.
struct results {
  uint64_t sum_lat_ns;  ///< Sum of submit to callback latencies.
  int64_t submitted;  ///< Frames handed to the encoder so far.
  int completed;  ///< Completed frames observed.
  int failed_submits;  ///< EncodeFrame calls that returned an error.
  int dropped;  ///< Frames the encoder reported as dropped instead of queuing.
  int out_of_order;  ///< Completions that arrived out of submission order.
  int last_index;  ///< Index of the previous completion.
  int min_window, max_window;  ///< Observed in-flight extremes.
  int64_t window_hist[64];  ///< Histogram of observed in-flight depth, clamped to 63.
  uint64_t bytes;  ///< Total compressed bytes.
  int lat_us[8192];  ///< Per frame submit to callback latency in microseconds, by completion order.
};

static struct submit_record *g_records;
static int g_frames;
static int g_fps;
static struct results g_res;
static os_unfair_lock g_lock = OS_UNFAIR_LOCK_INIT;
static dispatch_semaphore_t g_slot;  ///< Posted when an in-flight slot frees, when capped.
static dispatch_semaphore_t g_drained;  ///< Posted by every completion so --drain-each can wait.
static bool g_drain_each;  ///< When true, CompleteFrames is called after each submission.
static bool g_ffmpeg_pop;  ///< When true, mimic FFmpeg: the callback only enqueues, one non-blocking pop per submission.
static int g_force_key;  ///< When nonzero, force an IDR every N frames to induce a slow completion.
static int g_cb_delay_ms;  ///< Delay before the output callback reports its frame, to induce late completions.
static int g_drain_lag;  ///< Drain up to frame (i - N): bound the queue while still overlapping one encode.
static int g_misses;  ///< Pops that found the wrapper queue empty; each one is a permanent frame of latency.
static int g_popped;  ///< Packets handed out by the FFmpeg-style pop.
static int g_eof_drained;  ///< Packets still queued when the session was flushed at the end.

/// The wrapper queue: frame indices in completion order, mimicking VTEncContext.frame_queue.
static int q_index[8192];
static uint64_t q_time[8192];
static uint64_t q_bytes[8192];
static int q_head;
static int q_tail;
static bool g_late_props;  ///< When true, set the window properties after PrepareToEncodeFrames.
static bool g_no_attrs;  ///< When true, create the session without source image buffer attributes.

/// @return Monotonic host time in nanoseconds.
static uint64_t
mono_ns(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (uint64_t) ts.tv_sec * 1000000000ull + (uint64_t) ts.tv_nsec;
}

/// Comparator for qsort over integer latencies.
/// @return -1, 0 or 1 depending on the ordering of the two values.
static int
compare_int(const void *a, const void *b) {
  int x = *(const int *) a;
  int y = *(const int *) b;
  return x < y ? -1 : (x > y ? 1 : 0);
}

static void record_index(int index, uint64_t now, uint64_t bytes);

/// Encode output callback: receives the sourceFrameRefCon we passed, which is the frame index.
static void
encode_output_cb(void *outputCallbackRefCon, void *sourceFrameRefCon, OSStatus status, VTEncodeInfoFlags infoFlags, CMSampleBufferRef sampleBuffer) {
  (void) outputCallbackRefCon;

  if (status != noErr || !sampleBuffer || (infoFlags & kVTEncodeInfo_FrameDropped)) {
    os_unfair_lock_lock(&g_lock);
    g_res.dropped++;
    os_unfair_lock_unlock(&g_lock);
    if (g_slot) {
      dispatch_semaphore_signal(g_slot);
    }
    return;
  }

  int index = (int) (intptr_t) sourceFrameRefCon;
  if (index < 0 || index >= g_frames || !g_records) {
    return;
  }

  if (g_cb_delay_ms > 0) {
    struct timespec nap = { .tv_sec = g_cb_delay_ms / 1000, .tv_nsec = (long) (g_cb_delay_ms % 1000) * 1000000L };
    nanosleep(&nap, NULL);
  }
  uint64_t now = mono_ns();

  if (g_ffmpeg_pop) {
    // FFmpeg's wrapper only appends here; the numbers are taken when a packet is popped.
    os_unfair_lock_lock(&g_lock);
    if (q_tail < (int) (sizeof(q_index) / sizeof(q_index[0]))) {
      q_index[q_tail] = index;
      q_time[q_tail] = now;
      q_bytes[q_tail] = sampleBuffer ? (uint64_t) CMBlockBufferGetDataLength(CMSampleBufferGetDataBuffer(sampleBuffer)) : 0;
      q_tail++;
    }
    os_unfair_lock_unlock(&g_lock);
  } else {
    uint64_t payload = sampleBuffer ? (uint64_t) CMBlockBufferGetDataLength(CMSampleBufferGetDataBuffer(sampleBuffer)) : 0;
    record_index(index, now, payload);
  }

  if (g_slot) {
    dispatch_semaphore_signal(g_slot);
  }
  dispatch_semaphore_signal(g_drained);
}

/// Record the window depth and the submit to consume latency for one frame.
/// @param index Frame number being accounted for.
/// @param now Monotonic host time of the accounting point.
static void
record_index(int index, uint64_t now, uint64_t bytes) {
  os_unfair_lock_lock(&g_lock);
  struct results *r = &g_res;
  int window = (int) r->submitted - index;  // Frames submitted but not yet completed for this one.

  if (r->completed == 0) {
    r->min_window = r->max_window = window;
  } else {
    r->min_window = MIN(r->min_window, window);
    r->max_window = MAX(r->max_window, window);
  }
  r->window_hist[window < 0 ? 0 : (window > 63 ? 63 : window)]++;
  r->sum_lat_ns += now - g_records[index].submit_ns;
  if (r->completed < (int) (sizeof(r->lat_us) / sizeof(r->lat_us[0]))) {
    r->lat_us[r->completed] = (int) ((now - g_records[index].submit_ns) / 1000ull);
  }
  r->bytes += bytes;
  if (index < r->last_index) {
    r->out_of_order++;
  }
  r->last_index = index;
  r->completed++;
  os_unfair_lock_unlock(&g_lock);
}

/// Pop at most one queued packet, the way FFmpeg's vtenc_q_pop(wait = 0) does.
/// @return The frame number handed out, or -1 when the queue was empty.
static int
pop_one_nonblocking(void) {
  int index = -1;
  os_unfair_lock_lock(&g_lock);
  if (q_head < q_tail) {
    index = q_index[q_head++];
  } else {
    g_misses++;
  }
  os_unfair_lock_unlock(&g_lock);

  if (index >= 0) {
    uint64_t payload;
    os_unfair_lock_lock(&g_lock);
    payload = q_bytes[q_head - 1];
    os_unfair_lock_unlock(&g_lock);
    g_popped++;
    record_index(index, mono_ns(), payload);
  }
  return index;
}

/// Set one session property and report the status code returned by this device.
static void
set_prop(VTCompressionSessionRef session, CFStringRef key, SInt32 value, const char *label) {
  CFNumberRef number = CFNumberCreate(NULL, kCFNumberSInt32Type, &value);
  OSStatus status = VTSessionSetProperty(session, key, number);
  CFRelease(number);
  printf("    set %-40s -> %d%s\n", label, (int) status, status == noErr ? "" : "  (rejected by this device)");
}

/// Set a boolean-valued property (some properties require CFBoolean, not CFNumber).
static void
set_bool(VTCompressionSessionRef session, CFStringRef key, bool value, const char *label) {
  CFBooleanRef flag = value ? kCFBooleanTrue : kCFBooleanFalse;
  OSStatus status = VTSessionSetProperty(session, key, flag);
  printf("    set %-40s -> %d%s\n", label, (int) status, status == noErr ? "" : "  (rejected by this device)");
}

/// Read a property back from the session and print what the encoder actually reports.
static void
show_prop(VTCompressionSessionRef session, CFStringRef key, const char *label) {
  CFTypeRef value = NULL;
  OSStatus status = VTSessionCopyProperty(session, key, kCFAllocatorDefault, &value);
  if (status != noErr || !value) {
    printf("    read %-41s -> status %d (no value)\n", label, (int) status);
    return;
  }
  if (CFGetTypeID(value) == CFBooleanGetTypeID()) {
    printf("    read %-41s -> %s\n", label, CFBooleanGetValue((CFBooleanRef) value) ? "true" : "false");
  } else if (CFGetTypeID(value) == CFNumberGetTypeID()) {
    SInt32 number = 0;
    CFNumberGetValue((CFNumberRef) value, kCFNumberSInt32Type, &number);
    printf("    read %-41s -> %d\n", label, (int) number);
  } else {
    printf("    read %-41s -> (other type)\n", label);
  }
  CFRelease(value);
}

/// Run one trial and print its measurement line.
static void
run_trial(const struct trial_config *cfg) {
  printf("  delay=%d inflight_cap=%d\n", cfg->delay_mode, cfg->inflight_cap);
  fflush(stdout);

  g_frames = cfg->frames;
  g_fps = cfg->fps;
  g_records = calloc((size_t) cfg->frames, sizeof(struct submit_record));
  memset(&g_res, 0, sizeof(g_res));
  // Every trial is its own encoder session, so the wrapper queue and its counters start empty.
  q_head = q_tail = 0;
  g_misses = g_popped = g_eof_drained = 0;
  g_slot = cfg->inflight_cap > 0 ? dispatch_semaphore_create(cfg->inflight_cap) : NULL;
  g_drained = dispatch_semaphore_create(0);

  CFMutableDictionaryRef spec = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
  CFDictionaryAddValue(spec, kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder, kCFBooleanTrue);
  CFDictionaryAddValue(spec, kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder, kCFBooleanTrue);
  CFDictionaryAddValue(spec, kVTVideoEncoderSpecification_EnableLowLatencyRateControl, kCFBooleanTrue);

  // The pixel format is requested through the source image buffer attributes dictionary.
  CFMutableDictionaryRef image_attrs = g_no_attrs ? NULL : CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
  SInt32 pix_fmt_copy = (SInt32) cfg->pix_fmt;
  SInt32 width_copy = (SInt32) cfg->width;
  SInt32 height_copy = (SInt32) cfg->height;
  CFNumberRef fmt_number = CFNumberCreate(NULL, kCFNumberSInt32Type, &pix_fmt_copy);
  CFNumberRef width_number = CFNumberCreate(NULL, kCFNumberSInt32Type, &width_copy);
  CFNumberRef height_number = CFNumberCreate(NULL, kCFNumberSInt32Type, &height_copy);
  if (image_attrs) {
  CFDictionarySetValue(image_attrs, kCVPixelBufferPixelFormatTypeKey, fmt_number);
  CFDictionarySetValue(image_attrs, kCVPixelBufferWidthKey, width_number);
  CFDictionarySetValue(image_attrs, kCVPixelBufferHeightKey, height_number);
  CFDictionarySetValue(image_attrs, kCVPixelBufferIOSurfacePropertiesKey, CFDictionaryCreate(NULL, NULL, NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks));
  }
  CFRelease(fmt_number);
  CFRelease(width_number);
  CFRelease(height_number);

  VTCompressionSessionRef session = NULL;
  OSStatus status = VTCompressionSessionCreate(NULL, cfg->width, cfg->height, cfg->codec, spec, image_attrs, NULL, encode_output_cb, NULL, &session);
  CFRelease(spec);
  if (image_attrs) {
    CFRelease(image_attrs);
  }
  if (status != noErr || !session) {
    printf("    VTCompressionSessionCreate -> %d (trial skipped)\n", (int) status);
    free(g_records);
    g_records = NULL;
    g_slot = NULL;
    return;
  }

  set_prop(session, kVTCompressionPropertyKey_RealTime, 1, "RealTime");
  set_prop(session, kVTCompressionPropertyKey_AverageBitRate, cfg->bitrate, "AverageBitRate");
  set_prop(session, kVTCompressionPropertyKey_ExpectedFrameRate, cfg->fps, "ExpectedFrameRate");
  set_bool(session, kVTCompressionPropertyKey_AllowFrameReordering, false, "AllowFrameReordering=false (CFBoolean)");
  set_prop(session, kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality, 1, "PrioritizeEncodingSpeedOverQuality");
  if (@available(macOS 15.0, *)) {
    set_prop(session, kVTCompressionPropertyKey_SuggestedLookAheadFrameCount, 0, "SuggestedLookAheadFrameCount");
  }
  if (cfg->delay_mode == -2) {
    printf("    set MaxFrameDelayCount                         -> unset (Apple default: unlimited)\n");
  } else {
    set_prop(session, kVTCompressionPropertyKey_MaxFrameDelayCount, cfg->delay_mode, "MaxFrameDelayCount");
  }

  CFTypeRef encoder_id = NULL;
  if (VTSessionCopyProperty(session, kVTCompressionPropertyKey_EncoderID, NULL, &encoder_id) == noErr && encoder_id) {
    printf("    encoder id: %s\n", [(NSString *) CFBridgingRelease(encoder_id) UTF8String]);
  }

  if (!g_late_props) {
    show_prop(session, kVTCompressionPropertyKey_AllowFrameReordering, "AllowFrameReordering");
    show_prop(session, kVTCompressionPropertyKey_MaxFrameDelayCount, "MaxFrameDelayCount");
  }
  VTCompressionSessionPrepareToEncodeFrames(session);
  if (g_late_props) {
    set_bool(session, kVTCompressionPropertyKey_AllowFrameReordering, false, "AllowFrameReordering=false after prepare");
    set_prop(session, kVTCompressionPropertyKey_MaxFrameDelayCount, cfg->delay_mode == -2 ? 1 : cfg->delay_mode, "MaxFrameDelayCount after prepare");
    show_prop(session, kVTCompressionPropertyKey_AllowFrameReordering, "AllowFrameReordering");
    show_prop(session, kVTCompressionPropertyKey_MaxFrameDelayCount, "MaxFrameDelayCount");
  }
  show_prop(session, kVTCompressionPropertyKey_RealTime, "RealTime");
  show_prop(session, kVTCompressionPropertyKey_ExpectedFrameRate, "ExpectedFrameRate");

  // Recycle a small ring of IOSurface-backed buffers. The encoder may still hold buffers we
  // rewrite, which is the same lifetime situation Lumen's capture guard handles.
  int pool_size = (cfg->inflight_cap > 0 ? cfg->inflight_cap : 4) + 4;
  CVPixelBufferRef *pool = calloc((size_t) pool_size, sizeof(CVPixelBufferRef));
  for (int i = 0; i < pool_size; i++) {
    CFMutableDictionaryRef props = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFDictionarySetValue(props, kCVPixelBufferIOSurfacePropertiesKey, CFDictionaryCreate(NULL, NULL, NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks));
    OSStatus pbs = CVPixelBufferCreate(kCFAllocatorDefault, cfg->width, cfg->height, cfg->pix_fmt, props, &pool[i]);
    if (pbs != kCVReturnSuccess) {
      pool[i] = NULL;
    }
    CFRelease(props);
  }

  uint64_t start = mono_ns();
  uint64_t frame_interval_ns = 1000000000ull / (uint64_t) cfg->fps;
  uint32_t lcg = 12345u;

  for (int i = 0; i < cfg->frames; i++) {
    if (g_slot) {
      dispatch_semaphore_wait(g_slot, DISPATCH_TIME_FOREVER);
    }

    CVPixelBufferRef pb = pool[i % pool_size];
    if (pb) {
      CVPixelBufferLockBaseAddress(pb, 0);
      size_t stride = CVPixelBufferGetBytesPerRowOfPlane(pb, 0);
      uint8_t *luma = CVPixelBufferGetBaseAddressOfPlane(pb, 0);
      size_t planes = CVPixelBufferGetPlaneCount(pb);
      if (luma) {
        for (size_t y = 0; y < (size_t) cfg->height; y++) {
          uint8_t *row = luma + y * stride;
          if (cfg->noise) {
            for (size_t x = 0; x < stride; x++) {
              lcg = lcg * 1664525u + 1013904223u;
              row[x] = (uint8_t) (lcg >> 24);
            }
          } else {
            memset(row, (int) (((i * 3) + y) & 0xff), stride);
          }
        }
      }
      for (size_t p = 1; p < planes; p++) {
        uint8_t *chroma = CVPixelBufferGetBaseAddressOfPlane(pb, p);
        if (chroma) {
          memset(chroma, (i * 5) & 0xff, CVPixelBufferGetBytesPerRowOfPlane(pb, p) * (size_t) (cfg->height / 2));
        }
      }
      CVPixelBufferUnlockBaseAddress(pb, 0);
    }

    g_records[i].submit_ns = mono_ns();
    os_unfair_lock_lock(&g_lock);
    g_res.submitted++;
    os_unfair_lock_unlock(&g_lock);

    CFMutableDictionaryRef frame_props = NULL;
    if (g_force_key > 0 && (i % g_force_key) == (g_force_key - 1)) {
      frame_props = CFDictionaryCreateMutable(NULL, 1, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
      CFDictionarySetValue(frame_props, kVTEncodeFrameOptionKey_ForceKeyFrame, kCFBooleanTrue);
    }

    status = VTCompressionSessionEncodeFrame(session, pb, CMTimeMake(i, cfg->fps), kCMTimeInvalid, frame_props, (void *) (intptr_t) i, NULL);
    if (frame_props) {
      CFRelease(frame_props);
    }
    if (status != noErr) {
      os_unfair_lock_lock(&g_lock);
      g_res.failed_submits++;
      os_unfair_lock_unlock(&g_lock);
      if (g_slot) {
        dispatch_semaphore_signal(g_slot);
      }
    }

    if (g_drain_each) {
      // Drain up to and including this frame, then wait for its completion.
      VTCompressionSessionCompleteFrames(session, CMTimeMake(i, cfg->fps));
      if (!g_slot) {
        dispatch_semaphore_wait(g_drained, dispatch_time(DISPATCH_TIME_NOW, (int64_t) (3 * 1e9)));
      }
    }

    if (g_drain_lag > 0 && i >= g_drain_lag) {
      // Force the oldest outstanding frame out before popping, but let the newest one stay inside
      // the encoder so its cost still overlaps the next capture interval.
      VTCompressionSessionCompleteFrames(session, CMTimeMake(i - g_drain_lag, cfg->fps));
    }

    if (g_ffmpeg_pop) {
      // One non-blocking pop per submitted frame, exactly like encode_simple_internal() paired
      // with vtenc_q_pop(wait = 0): a late completion costs a frame of latency forever.
      pop_one_nonblocking();
    }

    // Pace submissions to the display cadence, like ScreenCaptureKit would.
    uint64_t deadline = start + (uint64_t) (i + 1) * frame_interval_ns;
    while (mono_ns() < deadline) {
      struct timespec nap = { .tv_sec = 0, .tv_nsec = 200000 };
      nanosleep(&nap, NULL);
    }
  }

  uint64_t submit_done = mono_ns();
  VTCompressionSessionCompleteFrames(session, kCMTimeInvalid);

  if (g_ffmpeg_pop) {
    // Count what FFmpeg would only hand out after the NULL-frame flush.
    os_unfair_lock_lock(&g_lock);
    g_eof_drained = q_tail - q_head;
    os_unfair_lock_unlock(&g_lock);
  }

  // Drain until completions stop arriving.
  int previous = -1;
  while (mono_ns() - submit_done < 10ull * 1000 * 1000 * 1000) {
    os_unfair_lock_lock(&g_lock);
    int current = g_res.completed;
    os_unfair_lock_unlock(&g_lock);
    if (current == previous && current >= (int) g_res.submitted) {
      break;
    }
    if (current == previous && mono_ns() - submit_done > 2ull * 1000 * 1000 * 1000) {
      break;
    }
    previous = current;
    struct timespec nap = { .tv_sec = 0, .tv_nsec = 100000 };
    nanosleep(&nap, NULL);
  }

  // Percentiles of submit to callback latency, taken from the per frame samples.
  int n = g_res.completed;
  if (n > (int) (sizeof(g_res.lat_us) / sizeof(g_res.lat_us[0]))) {
    n = (int) (sizeof(g_res.lat_us) / sizeof(g_res.lat_us[0]));
  }
  int *lat = calloc((size_t) (n > 0 ? n : 1), sizeof(int));
  memcpy(lat, g_res.lat_us, (size_t) n * sizeof(int));
  qsort(lat, (size_t) n, sizeof(int), compare_int);
  uint64_t total_lat_ns = g_res.sum_lat_ns;

  double wall_s = (double) (submit_done - start) / 1e9;
  double submit_fps = wall_s > 0 ? (double) cfg->frames / wall_s : 0;
  double avg_lat_ms = n > 0 ? (double) total_lat_ns / (double) n / 1e6 : 0;
  double drain_ms = (double) (mono_ns() - submit_done) / 1e6;

  printf("    result: %spopped %d/%d (misses %d, left in queue at EOF %d) | completed %d/%d (submit %.2f fps, failed %d, dropped %d) | window D min/max = %d/%d | "
         "submit->output avg %.2f ms p50 %.2f p90 %.2f max %.2f | out-of-order %d | %.2f Mbit/s | drain %.0f ms\n",
    g_ffmpeg_pop ? "ffmpeg-pop: " : "", g_popped, cfg->frames, g_misses, g_eof_drained,
    n, cfg->frames, submit_fps, g_res.failed_submits, g_res.dropped, g_res.min_window, g_res.max_window, avg_lat_ms,
    n > 0 ? lat[n / 2] / 1000.0 : 0.0, n > 0 ? lat[(int) ((double) n * 0.9 < (double) (n - 1) ? (int) ((double) n * 0.9) : n - 1)] / 1000.0 : 0.0,
    n > 0 ? lat[n - 1] / 1000.0 : 0.0, g_res.out_of_order,
    (double) g_res.bytes * 8.0 / (wall_s > 0 ? wall_s : 1.0) / 1e6, drain_ms);
  printf("    window histogram:");
  int shown = 0;
  for (int d = 0; d <= 63; d++) {
    if (g_res.window_hist[d]) {
      printf(" D%d:%lld", d, (long long) g_res.window_hist[d]);
      shown++;
      if (shown >= 12) {
        printf(" ...");
        break;
      }
    }
  }
  printf("\n\n");
  fflush(stdout);

  free(lat);
  VTCompressionSessionInvalidate(session);
  CFRelease(session);
  for (int i = 0; i < pool_size; i++) {
    if (pool[i]) {
      CFRelease(pool[i]);
    }
  }
  free(pool);
  free(g_records);
  g_records = NULL;
  g_slot = NULL;
}

/// Parse a comma separated integer list.
/// @return The number of values stored.
static int
parse_list(const char *text, int *out, int max) {
  int count = 0;
  const char *p = text;
  while (*p && count < max) {
    out[count++] = (int) strtol(p, (char **) &p, 10);
    if (*p == ',') {
      p++;
    }
  }
  return count;
}

int
main(int argc, char **argv) {
  @autoreleasepool {
    setvbuf(stdout, NULL, _IONBF, 0);
    struct trial_config cfg = { 0 };
    cfg.codec = kCMVideoCodecType_HEVC;
    cfg.pix_fmt = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;    cfg.width = 2560;
    cfg.height = 1920;
    cfg.fps = 60;
    cfg.frames = 120;
    cfg.bitrate = 36588000;

    int delays[8] = { -2, -1, 1, 0 };
    int delay_count = 4;
    int caps[8] = { 0, 2 };
    int cap_count = 2;

    for (int i = 1; i < argc; i++) {
      const char *arg = argv[i];
      if (!strcmp(arg, "--codec") && i + 1 < argc) {
        cfg.codec = !strcmp(argv[++i], "h264") ? kCMVideoCodecType_H264 : kCMVideoCodecType_HEVC;      } else if (!strcmp(arg, "--w") && i + 1 < argc) {
        cfg.width = atoi(argv[++i]);
      } else if (!strcmp(arg, "--h") && i + 1 < argc) {
        cfg.height = atoi(argv[++i]);
      } else if (!strcmp(arg, "--fps") && i + 1 < argc) {
        cfg.fps = atoi(argv[++i]);
      } else if (!strcmp(arg, "--frames") && i + 1 < argc) {
        cfg.frames = atoi(argv[++i]);
      } else if (!strcmp(arg, "--bitrate") && i + 1 < argc) {
        cfg.bitrate = atoi(argv[++i]);
      } else if (!strcmp(arg, "--delay") && i + 1 < argc) {
        delay_count = parse_list(argv[++i], delays, 8);
      } else if (!strcmp(arg, "--inflight") && i + 1 < argc) {
        cap_count = parse_list(argv[++i], caps, 8);
      } else if (!strcmp(arg, "--drain-lag") && i + 1 < argc) {
        g_drain_lag = atoi(argv[++i]);
      } else if (!strcmp(arg, "--ffmpeg-pop")) {
        g_ffmpeg_pop = true;
      } else if (!strcmp(arg, "--spike") && i + 1 < argc) {
        g_force_key = atoi(argv[++i]);
      } else if (!strcmp(arg, "--cb-delay") && i + 1 < argc) {
        g_cb_delay_ms = atoi(argv[++i]);
      } else if (!strcmp(arg, "--drain-each")) {
        g_drain_each = true;
      } else if (!strcmp(arg, "--late-props")) {
        g_late_props = true;
      } else if (!strcmp(arg, "--no-attrs")) {
        g_no_attrs = true;
      } else if (!strcmp(arg, "--noise")) {
        cfg.noise = true;
      } else if (!strcmp(arg, "--tenbit")) {
        cfg.pix_fmt = kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange;
      } else {
        printf("usage: vtprobe [--codec h264|hevc] [--w N] [--h N] [--fps N] [--frames N] [--bitrate N]\n"
               "               [--delay -2,-1,1,0] [--inflight 0,1,2] [--noise] [--tenbit]\n"
               "[--ffmpeg-pop] [--spike N] [--cb-delay MS] [--drain-each]\n"
               "  --ffmpeg-pop: mimic FFmpeg (callback only enqueues, one pop per submit)\n"
               "  delay: -2 leave MaxFrameDelayCount unset, -1 unlimited (Apple default), N hold at most N\n");
        return 2;
      }
    }

    printf("vtprobe: %s %dx%d@%d, %d frames, %d bit/s, noise=%d, tenbit=%d\n", cfg.codec == kCMVideoCodecType_H264 ? "H.264" : "HEVC",
      cfg.width, cfg.height, cfg.fps, cfg.frames, cfg.bitrate, (int) cfg.noise, cfg.pix_fmt == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange);
    fflush(stdout);

    for (int d = 0; d < delay_count; d++) {
      for (int c = 0; c < cap_count; c++) {
        struct trial_config trial = cfg;
        trial.delay_mode = delays[d];
        trial.inflight_cap = caps[c];
        run_trial(&trial);
      }
    }
  }
  return 0;
}
