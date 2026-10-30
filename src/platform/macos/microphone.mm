/**
 * @file src/platform/macos/microphone.mm
 * @brief Definitions for microphone capture on macOS.
 */
// local includes
#include "src/config.h"
#include "src/logging.h"
#include "src/platform/common.h"
#include "src/platform/macos/audio_capture.h"
#include "src/platform/macos/audio_consumer_gate.h"
#include "src/platform/macos/av_audio.h"
#include "src/platform/macos/sc_audio.h"

namespace platf {
  using namespace std::literals;

  /**
   * @brief macOS microphone capture device and audio format state.
   */
  struct av_mic_t: public mic_t {
    AVAudio *av_audio_capture {};  ///< AV audio capture.

    ~av_mic_t() override {
      [av_audio_capture release];
    }

    /**
     * @brief Deliver a captured audio sample to Sunshine's audio pipeline.
     *
     * @param sample_in Sample in.
     * @return Capture status reported to the streaming pipeline.
     */
    capture_e sample(std::vector<float> &sample_in) override {
      const uint32_t neededBytes = static_cast<uint32_t>(sample_in.size() * sizeof(float));
      uint8_t *dst = reinterpret_cast<uint8_t *>(sample_in.data());

      uint32_t remaining = neededBytes;

      while (remaining > 0) {
        uint32_t avail = 0;
        void *tail = TPCircularBufferTail(&av_audio_capture->audioSampleBuffer, &avail);

        if (avail == 0) {
          const auto wait_started = std::chrono::steady_clock::now();
          const auto status = platf::audio_wait_for_data(
            av_audio_capture->audioSemaphore,
            av_audio_capture->consumerWaiting,
            audio_wait_timeout,
            [this]() {
              uint32_t pending = 0;
              TPCircularBufferTail(&av_audio_capture->audioSampleBuffer, &pending);
              return pending > 0;
            }
          );

          report_audio_wait(status, std::chrono::steady_clock::now() - wait_started);

          if (status == platf::audio_wait_e::timed_out) {
            BOOST_LOG(warning) << "Audio sample timeout - no audio data received within "sv << audio_wait_timeout.count() << "ms"sv;

            // Silence is returned to the pipeline, which still submits the frame, so the client
            // keeps receiving audio at the expected rate instead of a gap
            std::fill(sample_in.begin(), sample_in.end(), 0.0f);
            return capture_e::timeout;
          }

          continue;
        }

        const uint32_t toCopy = (avail < remaining) ? avail : remaining;
        std::memcpy(dst, tail, toCopy);

        TPCircularBufferConsume(&av_audio_capture->audioSampleBuffer, toCopy);

        dst += toCopy;
        remaining -= toCopy;
      }

      return capture_e::ok;
    }

    /**
     * @brief Report how long the consumer waited for samples and why the wait ended.
     *
     * The wait time is the observable cost of the CoreAudio IOProc cadence: a granted buffer size
     * larger than the requested audio frame shows up here as a steady floor. A spurious wait
     * result means a semaphore token was left behind, which is the failure mode this path is
     * designed to prevent, so it is reported as a warning rather than counted silently.
     *
     * @param status Result of the wait.
     * @param waited How long the wait took.
     */
    void report_audio_wait(platf::audio_wait_e status, std::chrono::steady_clock::duration waited) {
      wait_latency_logger.collect_and_log(std::chrono::duration<double, std::milli> {waited}.count());

      if (status == platf::audio_wait_e::spurious) {
        ++stale_wakeups;
      }

      const auto now = std::chrono::steady_clock::now();
      if (now - last_audio_report < audio_report_interval) {
        return;
      }
      last_audio_report = now;

      const auto failures = av_audio_capture->converterFailures.load(std::memory_order_relaxed);
      if (stale_wakeups > 0) {
        BOOST_LOG(warning) << "Audio: "sv << stale_wakeups << " stale wakeups since the last report"sv;
        stale_wakeups = 0;
      }
      if (failures != reported_converter_failures) {
        BOOST_LOG(warning) << "Audio: "sv << failures << " converter failures total, silence substituted for the affected frames"sv;
        reported_converter_failures = failures;
      }
    }

    /**
     * @brief Periodic aggregate of consumer wait time, reported at debug severity.
     */
    logging::min_max_avg_periodic_logger<double> wait_latency_logger {debug, "Audio: consumer wait", "ms"};

    /**
     * @brief How long to wait for a producer signal before giving up on the current frame.
     */
    static constexpr std::chrono::milliseconds audio_wait_timeout {200};

    /**
     * @brief Minimum spacing between summary warnings for stale wakeups and converter failures.
     */
    static constexpr std::chrono::seconds audio_report_interval {10};

    uint64_t stale_wakeups {};  ///< Waits that consumed a semaphore token without finding samples.
    uint64_t reported_converter_failures {};  ///< Converter failure count already reported.
    std::chrono::steady_clock::time_point last_audio_report {std::chrono::steady_clock::now()};  ///< Last summary report timestamp.
  };

  /**
   * @brief System audio capture using ScreenCaptureKit (macOS 12.3+)
   */
  struct sc_mic_t: public mic_t {
    SCAudioCapture *sc_audio_capture API_AVAILABLE(macos(12.3)) {};  ///< ScreenCaptureKit capture session.

    /**
     * @brief Release the fallback capture session.
     */
    ~sc_mic_t() override {
      if (@available(macOS 12.3, *)) {
        [sc_audio_capture release];
      }
    }

    /**
     * @brief Read a complete audio frame with a bounded wait for shutdown.
     * @param sample_in Destination interleaved float samples.
     * @return Capture status, including timeout when no full frame arrives.
     */
    capture_e sample(std::vector<float> &sample_in) override {
      if (@available(macOS 12.3, *)) {
        auto sample_size = sample_in.size();

        uint32_t length = 0;
        TPCircularBuffer *buffer = [sc_audio_capture getAudioBuffer];
        void *byteSampleBuffer = TPCircularBufferTail(buffer, &length);

        int wait_count = 0;
        while (length < sample_size * sizeof(float)) {
          if (!sc_audio_capture.isCapturing) {
            return capture_e::error;
          }
          [sc_audio_capture.samplesArrivedSignal lock];
          [sc_audio_capture.samplesArrivedSignal waitUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
          [sc_audio_capture.samplesArrivedSignal unlock];
          byteSampleBuffer = TPCircularBufferTail(buffer, &length);
          // After 500ms of no data, return timeout so the caller can check shutdown_event
          if (++wait_count > 5 && length < sample_size * sizeof(float)) {
            return capture_e::timeout;
          }
        }

        const float *sampleBuffer = (float *) byteSampleBuffer;
        std::vector<float> vectorBuffer(sampleBuffer, sampleBuffer + sample_size);

        std::copy_n(std::begin(vectorBuffer), sample_size, std::begin(sample_in));

        TPCircularBufferConsume(buffer, (uint32_t) sample_size * sizeof(float));

        return capture_e::ok;
      }
      return capture_e::error;
    }
  };

  /**
   * @brief macOS audio control state used to create microphone streams.
   */
  struct macos_audio_control_t: public audio_control_t {
    AVCaptureDevice *audio_capture_device {};  ///< Audio capture device.

  public:
    /**
     * @brief Update the sink value on the backend.
     *
     * @param sink Audio sink name to route or capture.
     * @return Status from updating sink.
     */
    int set_sink(const std::string &sink) override {
      BOOST_LOG(warning) << "audio_control_t::set_sink() unimplemented: "sv << sink;
      return 0;
    }

    /**
     * @brief Create a microphone capture stream for the requested layout.
     *
     * @param mapping Opus channel mapping table for the requested layout.
     * @param channels Number of audio channels in the stream.
     * @param sample_rate Audio sample rate in hertz.
     * @param frame_size Number of samples captured per audio frame.
     * @param continuous_audio Continuous audio.
     * @param host_audio_enabled Whether host playback should remain enabled during capture.
     * @return Microphone capture object for the requested audio layout.
     */
    std::unique_ptr<mic_t> microphone(const std::uint8_t *mapping, int channels, std::uint32_t sample_rate, std::uint32_t frame_size, bool continuous_audio, bool host_audio_enabled) override {
      auto mic = std::make_unique<av_mic_t>();
      mic->av_audio_capture = [[AVAudio alloc] init];

      // Set the host audio enabled flag from the stream configuration
      mic->av_audio_capture.hostAudioEnabled = host_audio_enabled ? YES : NO;
      BOOST_LOG(debug) << "Set hostAudioEnabled to: "sv << (host_audio_enabled ? "YES" : "NO");

      if (macos::is_system_audio_sink(config::audio.sink)) {
        // Use macOS system-wide audio tap
        BOOST_LOG(info) << "Using macOS system audio tap for capture."sv;
        BOOST_LOG(info) << "Sample rate: "sv << sample_rate << ", Frame size: "sv << frame_size << ", Channels: "sv << channels;

        if ([mic->av_audio_capture setupSystemTap:sample_rate frameSize:frame_size channels:channels]) {
          BOOST_LOG(warning) << "System audio tap failed; trying ScreenCaptureKit audio capture."sv;
          // Release any partial aggregate device before starting the fallback.
          mic.reset();
          if (@available(macOS 12.3, *)) {
            auto fallback = std::make_unique<sc_mic_t>();
            fallback->sc_audio_capture = [[SCAudioCapture alloc] init];
            if (fallback->sc_audio_capture && [fallback->sc_audio_capture startCaptureWithSampleRate:sample_rate
                                                                                            channels:channels] == 0) {
              if (!host_audio_enabled) {
                BOOST_LOG(warning) << "ScreenCaptureKit fallback cannot mute host audio."sv;
              }
              return fallback;
            }
          }
          BOOST_LOG(error) << "Both system audio capture backends failed."sv;
          return nullptr;
        }
      } else {
        // Use specified macOS audio sink
        const char *audio_sink = config::audio.sink.c_str();
        BOOST_LOG(info) << "Using configured audio sink "sv << audio_sink << " for capture."sv;

        if (!request_microphone_permission()) {
          return nullptr;
        }

        if ((audio_capture_device = [AVAudio findMicrophone:[NSString stringWithUTF8String:audio_sink]]) == nullptr) {
          BOOST_LOG(error) << "opening microphone '"sv << audio_sink << "' failed. Please set a valid input source in the Sunshine config."sv;
          BOOST_LOG(error) << "Available inputs:"sv;

          for (NSString *name in [AVAudio microphoneNames]) {
            BOOST_LOG(error) << "\t"sv << [name UTF8String];
          }

          return nullptr;
        }

        if ([mic->av_audio_capture setupMicrophone:audio_capture_device sampleRate:sample_rate frameSize:frame_size channels:channels]) {
          BOOST_LOG(error) << "Failed to setup microphone."sv;
          return nullptr;
        }
      }

      return mic;
    }

    bool is_sink_available(const std::string &sink) override {
      BOOST_LOG(warning) << "audio_control_t::is_sink_available() unimplemented: "sv << sink;
      return true;
    }

    /**
     * @brief Query host and virtual sink names available to Sunshine.
     *
     * @return Host and virtual sink names when the backend can report them.
     */
    std::optional<sink_t> sink_info() override {
      sink_t sink;

      return sink;
    }
  };

  std::unique_ptr<audio_control_t> audio_control() {
    return std::make_unique<macos_audio_control_t>();
  }
}  // namespace platf
