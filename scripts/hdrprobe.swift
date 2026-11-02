// hdrprobe.swift
//
// Answers one question empirically: can this Mac hand ScreenCaptureKit-captured HDR pixels to a
// VideoToolbox encoder? It prints the EDR state of every attached display, then captures frames in
// three configurations and dumps the colour attachments that come back, because the attachments are
// what a decoder (and therefore Moonlight) needs in order to know the frames are PQ/BT.2020.
//
// Build:  swiftc -framework AppKit -framework ScreenCaptureKit -framework CoreMedia \
//           -framework CoreVideo hdrprobe.swift -o hdrprobe
// Needs Screen Recording permission for the binary that runs it.

import AppKit
import CoreMedia
import CoreVideo
import ScreenCaptureKit

/// Frames to keep before stopping the stream.
let wantedFrames = 8

/// Run only the extended-range ceiling sweep, so the question "how far above SDR white gets through"
/// can be re-asked without replaying every other configuration.
let onlyExtendedSweep = CommandLine.arguments.contains("--edr-only")

/// Capture the screen as it is, with no window of our own on it, to measure real content such as an
/// HDR video playing in a browser. Luma is then sampled across the whole frame, not the centre.
let liveCapture = CommandLine.arguments.contains("--live")

/// Convert a four character code into the readable form used by CoreVideo format names.
func fourCC(_ code: OSType) -> String {
  var value = code.bigEndian
  var bytes: [UInt8] = []
  for _ in 0 ..< 4 {
    bytes.append(UInt8(truncatingIfNeeded: value & 0xff))
    value >>= 8
  }
  return String(bytes: bytes, encoding: .ascii) ?? String(format: "%08x", code)
}

/// Decode a normalised SMPTE ST 2084 code value into luminance.
///
/// - Parameter encoded: the code value normalised over the transfer-function domain, where 1.0 is
///   the PQ 10000 cd/m2 reference.
/// - Returns: luminance in candelas per square metre.
func pqNits(_ encoded: Double) -> Double {
  // ST 2084 / BT.2100 PQ constants. c2 and c3 are the /128 form, which is the pair that goes with
  // this arrangement of the EOTF; the /4096 products belong to the inverse transfer function.
  let m1 = 2610.0 / 16384.0
  let m2 = 2523.0 / 4096.0 * 128.0
  let c1 = 3424.0 / 4096.0
  let c2 = 2413.0 / 128.0
  let c3 = 2392.0 / 128.0
  let e = max(0.0, min(1.0, encoded))
  let p = pow(e, 1.0 / m2)
  let denominator = c2 - c3 * p
  guard denominator > 0 else {
    return 0
  }
  return pow(max(0.0, p - c1) / denominator, 1.0 / m1) * 10000
}

/// Report the 10-bit luma statistics of a biplanar buffer.
///
/// With `wholeFrame` every pixel is measured, which real content needs because the brightest
/// highlight can be anywhere. Otherwise the middle third is used so window borders, the menu bar and
/// the dock stay out of the measured region. The code value is reported raw, normalised over the
/// container's own range, and decoded through the PQ EOTF, because the decoded number is what
/// settles the SDR white level question in section 8 of docs/macos_hdr.md.
///
/// - Parameters:
///   - image: a captured frame, expected to be `x420` or `xf20`.
///   - wholeFrame: measure the entire frame instead of its middle third.
func reportLuma(_ image: CVImageBuffer, wholeFrame: Bool = false) {
  let format = fourCC(CVPixelBufferGetPixelFormatType(image))
  guard format == "x420" || format == "xf20" else {
    print("    luma: container \(format) is not 10-bit biplanar")
    return
  }
  let low = format == "x420" ? 64.0 : 0.0
  let high = format == "x420" ? 940.0 : 1023.0

  CVPixelBufferLockBaseAddress(image, .readOnly)
  defer { CVPixelBufferUnlockBaseAddress(image, .readOnly) }
  guard let base = CVPixelBufferGetBaseAddressOfPlane(image, 0) else {
    print("    luma: no plane 0 base address")
    return
  }

  let width = CVPixelBufferGetWidth(image)
  let height = CVPixelBufferGetHeight(image)
  let stride = CVPixelBufferGetBytesPerRowOfPlane(image, 0)
  let x0 = wholeFrame ? 0 : width / 3
  let x1 = wholeFrame ? width : width * 2 / 3
  let y0 = wholeFrame ? 0 : height / 3
  let y1 = wholeFrame ? height : height * 2 / 3

  var codes: [Int] = []
  codes.reserveCapacity((x1 - x0) * (y1 - y0))
  for row in y0 ..< y1 {
    let line = base.advanced(by: row &* stride).bindMemory(to: UInt16.self, capacity: width)
    for column in x0 ..< x1 {
      // Ten bits sit in the most significant bits of each 16 bit sample.
      codes.append(Int(line[column]) >> 6)
    }
  }
  guard !codes.isEmpty else {
    print("    luma: sampled region was empty")
    return
  }

  codes.sort()
  let median = codes[codes.count / 2]
  let scaled = (Double(median) - low) / (high - low)
  print("    luma \(format): min=\(codes.first ?? 0) median=\(median) max=\(codes.last ?? 0) (10 bit)")
  if wholeFrame {
    // Percentiles, because a single maximum is usually one noisy pixel rather than a highlight.
    for (name, index) in [("p50", codes.count / 2), ("p99", codes.count * 99 / 100), ("p9999", codes.count * 9999 / 10000)] {
      let value = codes[min(index, codes.count - 1)]
      let e = (Double(value) - low) / (high - low)
      print("    luma \(name)=\(value) normalised=\(String(format: "%.4f", e)) pq=\(String(format: "%.1f", pqNits(e))) cd/m2")
    }
  }

  // A PQ tag makes the code value an absolute luminance. Without one the buffer is SDR, and the same
  // number is only a fraction of white, so decoding it through the PQ curve would be a lie.
  var transfer = ""
  if let dict = CVBufferCopyAttachments(image, .shouldPropagate) as? [CFString: Any] {
    for (key, value) in dict where key as String == "CVImageBufferTransferFunction" {
      transfer = "\(value)"
    }
  }
  if transfer.contains("2084") {
    print("    luma normalised=\(String(format: "%.4f", scaled)) pq=\(String(format: "%.1f", pqNits(scaled))) cd/m2")
  } else {
    print("    luma normalised=\(String(format: "%.4f", scaled)) transfer=\(transfer.isEmpty ? "untagged" : transfer) "
      + "(SDR: a fraction of white, not nits)")
  }
}

/// Encode a linear multiple of SDR white in extended sRGB, the extended space AppKit exposes.
///
/// - Parameter multiple: 1.0 is SDR white, anything above it is the extra headroom an HDR surface has.
/// - Returns: the extended sRGB component value to paint.
func extendedSRGBEncoded(_ multiple: Double) -> CGFloat {
  CGFloat(1.055 * pow(multiple, 1.0 / 2.4) - 0.055)
}

/// Build a flat neutral colour in extended sRGB, which carries components above 1.0 to the window
/// server, unlike ordinary sRGB drawing.
///
/// - Parameter multiple: the linear multiple of SDR white to paint.
/// - Returns: a colour ready for `coverScreen`.
func edrWhite(_ multiple: Double) -> CGColor {
  let encoded = extendedSRGBEncoded(multiple)
  let space = CGColorSpace(name: CGColorSpace.extendedSRGB)!
  return CGColor(colorSpace: space, components: [encoded, encoded, encoded, 1])!
}

/// Place an opaque borderless window over the whole captured screen and leave it there.
///
/// A flat SDR window is the reference the SDR white measurement needs: it is ordinary SDR content,
/// which is exactly what a desktop stream is, so the captured luma of that window is the code value
/// an encoder would write for white. With `extendedRange` the window gets an extended colour space as
/// its backing store, which is how an HDR surface reaches the compositor and the only AppKit route
/// that keeps components above 1.0 in this SDK.
///
/// - Parameters:
///   - color: the flat colour to paint, in whatever colour space its components belong to.
///   - extendedRange: give the window an extended-range backing store.
/// - Returns: the ordered-front window, which the caller must keep retained while capturing.
@MainActor
func coverScreen(_ color: CGColor, extendedRange: Bool = false) -> NSWindow {
  NSApplication.shared.setActivationPolicy(.accessory)
  let screen = NSScreen.screens.first!
  let window = NSWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
  window.isOpaque = true
  if extendedRange {
    window.colorSpace = .extendedSRGB
  }
  window.backgroundColor = NSColor(cgColor: color)
  window.hasShadow = false
  window.level = .floating
  window.ignoresMouseEvents = true

  // The layer is the belt to backgroundColor's braces: layer background colours go to the window
  // server as the CGColor given, without AppKit re-deriving them during drawing.
  let surface = NSView(frame: screen.frame)
  surface.wantsLayer = true
  surface.layer?.backgroundColor = color
  window.contentView = surface

  window.setFrame(screen.frame, display: true)
  window.orderFrontRegardless()
  window.display()
  if extendedRange {
    print("  cover window colorSpace=\(window.colorSpace?.localizedName ?? "nil") "
      + "screen maximumEDR=\(screen.maximumExtendedDynamicRangeColorComponentValue)")
  }
  return window
}

/// Print every attachment on a buffer, using the public constants where they exist so the output
/// is readable, and falling back to the raw dictionary so nothing that Apple does tag is missed.
func dumpAttachments(_ buffer: CVBuffer, _ label: String) {
  guard let dict = CVBufferCopyAttachments(buffer, .shouldPropagate) as? [CFString: Any] else {
    print("    \(label): <no attachments>")
    return
  }

  for key in dict.keys.sorted(by: { (a: CFString, b: CFString) in String(a) < String(b) }) {
    let value = dict[key]!
    if CFGetTypeID(value as CFTypeRef) == CFDataGetTypeID() {
      let bytes = (value as! CFData as NSData) as Data
      var saved = ""
      // The raw key value, because CoreVideo's kCVImageBufferICCProfile is not imported into Swift.
      if key as String == "CVImageBufferICCProfile" {
        // Keep the profile on disk so its primaries and transfer curve can be inspected separately,
        // because an ICC-only attachment gives the encoder no transfer function to write.
        let url = URL(fileURLWithPath: "/tmp/hdrprobe_icc_\(label.replacingOccurrences(of: " ", with: "_")).icc")
        try? bytes.write(to: url)
        saved = " -> \(url.path)"
      }
      print("    \(key as String): <data \(bytes.count) bytes> \(bytes.prefix(16).map { String(format: "%02x", $0) }.joined(separator: " "))\(saved)")
    } else {
      print("    \(key as String): \(value)")
    }
  }
}

/// Report the HDR/EDR state of every screen, which has to be above 1.0 for any HDR content to exist.
func describeScreens() {
  print("== NSScreen EDR state ==")
  for (index, screen) in NSScreen.screens.enumerated() {
    let maximum = screen.maximumExtendedDynamicRangeColorComponentValue
    let potential = screen.maximumPotentialExtendedDynamicRangeColorComponentValue
    print("  screen \(index): \(screen.localizedName)")
    print("    maximumEDR=\(maximum) potentialEDR=\(potential)")
    print("    colorSpace=\(screen.colorSpace?.localizedName ?? "nil")")
  }
}

/// Receives frames and prints the first few in full.
final class FramePrinter: NSObject, SCStreamOutput {
  let label: String
  var printed = 0
  /// Report the centre luma of each printed frame, used by the flat-colour white probe.
  let wantsLuma: Bool
  /// How many frames to print in full; live content needs more than a flat patch does.
  let printLimit: Int
  /// Sample the whole frame rather than its middle third.
  let wholeFrameLuma: Bool

  /// Prepare a printer for one capture configuration.
  init(_ label: String, wantsLuma: Bool = false, printLimit: Int = 3, wholeFrameLuma: Bool = false) {
    self.label = label
    self.wantsLuma = wantsLuma
    self.printLimit = printLimit
    self.wholeFrameLuma = wholeFrameLuma
  }

  func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
    guard printed < wantedFrames else {
      return
    }

    printed += 1
    guard printed <= printLimit, let image = CMSampleBufferGetImageBuffer(sampleBuffer) else {
      return
    }

    let format = CVPixelBufferGetPixelFormatType(image)
    print("  [\(label)] frame \(printed): \(fourCC(format)) "
      + "\(CVPixelBufferGetWidth(image))x\(CVPixelBufferGetHeight(image)) "
      + "planes=\(CVPixelBufferGetPlaneCount(image))")
    dumpAttachments(image, "attachments")

    if wantsLuma {
      reportLuma(image, wholeFrame: wholeFrameLuma)
    }
  }
}

/// Run one capture and report what the encoder would receive.
///
/// - Parameters:
///   - label: name of this configuration in the log.
///   - windowColor: when set, an opaque window of this colour covers the display first, so the luma
///     measurement has a known reference on screen.
///   - windowExtendedRange: give that window an extended dynamic range backing store.
///   - wantsLuma: sample the centre luma of the delivered frames.
///   - configure: applied to the stream configuration before capture starts.
@MainActor
func capture(
  _ label: String, windowColor: CGColor? = nil, windowExtendedRange: Bool = false, wantsLuma: Bool = false,
  wholeFrameLuma: Bool = false,
  configure: (SCStreamConfiguration, SCDisplay) -> Void
) async {
  print("\n== capture [\(label)] ==")

  let content: SCShareableContent?
  do {
    content = try await SCShareableContent.current
  } catch {
    print("  getShareableContent failed: \(error)")
    return
  }

  guard let display = content?.displays.first else {
    print("  no display available")
    return
  }

  let config = SCStreamConfiguration()
  config.width = Int(display.width)
  config.height = Int(display.height)
  config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
  config.queueDepth = 4
  config.showsCursor = false
  configure(config, display)

  print("  requested: pixelFormat=\(fourCC(config.pixelFormat)) colorSpace=\(config.colorSpaceName as String)"
    + " captureDynamicRange=\(config.captureDynamicRange.rawValue) matrix=\(config.colorMatrix as String)")

  // The window has to be on screen and composited before the first frame is worth sampling.
  var cover: NSWindow?
  if let windowColor {
    cover = coverScreen(windowColor, extendedRange: windowExtendedRange)
    try? await Task.sleep(for: .seconds(0.5))
    // EDR headroom is only granted while something asks for it, so read it with the window up.
    if windowExtendedRange, let screen = NSScreen.screens.first {
      print("  screen EDR with window up: maximum=\(screen.maximumExtendedDynamicRangeColorComponentValue)"
        + " potential=\(screen.maximumPotentialExtendedDynamicRangeColorComponentValue)")
    }
  }
  defer { cover?.orderOut(nil) }

  let stream = SCStream(filter: SCContentFilter(display: display, excludingWindows: []), configuration: config, delegate: nil)
  let printer = FramePrinter(label, wantsLuma: wantsLuma, printLimit: wholeFrameLuma ? wantedFrames : 3,
    wholeFrameLuma: wholeFrameLuma)

  do {
    try stream.addStreamOutput(printer, type: .screen, sampleHandlerQueue: nil)
    try await stream.startCapture()
  } catch {
    print("  capture setup failed: \(error)")
    return
  }

  // Give the stream a moment to deliver frames before tearing it down. Live content is measured over
  // a longer window so a bright highlight has a chance to appear in the sampled frames.
  try? await Task.sleep(for: .seconds(wholeFrameLuma ? 5.0 : 2.0))

  do {
    try await stream.stopCapture()
  } catch {
    print("  stopCapture: \(error)")
  }

  print("  frames delivered: \(printer.printed)")
}

describeScreens()

if !onlyExtendedSweep, !liveCapture {
  await capture("SDR/BGRA (what Lumen requests today)") { config, _ in
    config.pixelFormat = kCVPixelFormatType_32BGRA
  }

  await capture("SDR/420v10p") { config, _ in
    config.pixelFormat = kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
  }
}

if !onlyExtendedSweep, !liveCapture, #available(macOS 15.0, *) {
  await capture("HDR canonical display (preset)") { config, _ in
    let preset = SCStreamConfiguration(preset: .captureHDRStreamCanonicalDisplay)
    config.captureDynamicRange = preset.captureDynamicRange
    config.pixelFormat = preset.pixelFormat
    config.colorSpaceName = preset.colorSpaceName
    config.colorMatrix = preset.colorMatrix
  }

  await capture("HDR local display (preset)") { config, _ in
    let preset = SCStreamConfiguration(preset: .captureHDRStreamLocalDisplay)
    config.captureDynamicRange = preset.captureDynamicRange
    config.pixelFormat = preset.pixelFormat
    config.colorSpaceName = preset.colorSpaceName
    config.colorMatrix = preset.colorMatrix
  }

  await capture("HDR canonical display (manual 420v10p)") { config, _ in
    config.captureDynamicRange = .hdrCanonicalDisplay
    config.pixelFormat = kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
  }

  // The requests Lumen would actually make. The presets answer with P3-D65 primaries, so these ask
  // whether Rec.2100 primaries are obtainable at all, and whether the video-range container Lumen
  // uses today behaves differently from the full-range container the presets choose.
  await capture("HDR_canonical_420v10p_ITUR_2100_PQ") { config, _ in
    config.captureDynamicRange = .hdrCanonicalDisplay
    config.pixelFormat = kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
    config.colorSpaceName = CGColorSpace.itur_2100_PQ as CFString
  }

  await capture("HDR_canonical_420f10p_ITUR_2100_PQ") { config, _ in
    config.captureDynamicRange = .hdrCanonicalDisplay
    config.pixelFormat = kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
    config.colorSpaceName = CGColorSpace.itur_2100_PQ as CFString
  }

  await capture("HDR_canonical_420v10p_DisplayP3_PQ") { config, _ in
    config.captureDynamicRange = .hdrCanonicalDisplay
    config.pixelFormat = kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
    config.colorSpaceName = CGColorSpace.displayP3_PQ as CFString
  }

  await capture("HDR_local_420v10p_ITUR_2100_PQ") { config, _ in
    config.captureDynamicRange = .hdrLocalDisplay
    config.pixelFormat = kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
    config.colorSpaceName = CGColorSpace.itur_2100_PQ as CFString
  }

  await capture("HDR_canonical_420v10p_ITUR_2100_PQ_matrix_2020") { config, _ in
    config.captureDynamicRange = .hdrCanonicalDisplay
    config.pixelFormat = kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
    config.colorSpaceName = CGColorSpace.itur_2100_PQ as CFString
    config.colorMatrix = kCVImageBufferYCbCrMatrix_ITU_R_2020 as CFString
  }
} else {
  print("\nHDR capture needs macOS 15 or newer")
}

// Where does SDR white land in the PQ stream? This is the measurement section 8 question 2 of
// docs/macos_hdr.md needs, because it decides whether the 2.03 scaling pass is really required.
// Each patch is an ordinary SDR window, so whatever code value comes back is what a desktop's white
// would be encoded as, and the PQ decoding says the luminance the client would show for it.
if !onlyExtendedSweep, !liveCapture, #available(macOS 15.0, *) {
  let patches: [(String, CGColor)] = [
    ("white", NSColor.white.cgColor),
    ("gray50", NSColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 1).cgColor),
    ("gray18", NSColor(srgbRed: 0.18, green: 0.18, blue: 0.18, alpha: 1).cgColor),
    ("black", NSColor.black.cgColor),
  ]

  for (patch, color) in patches {
    for container in ["420v10p", "420f10p"] {
      await capture("whiteprobe_canonical_\(patch)_\(container)", windowColor: color, wantsLuma: true) { config, _ in
        config.captureDynamicRange = .hdrCanonicalDisplay
        config.colorSpaceName = CGColorSpace.itur_2100_PQ as CFString
        config.pixelFormat = container == "420v10p"
          ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
          : kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
      }
    }

    // Local dynamic range is the only plausible way to move SDR white off the 100 cd/m2 canonical
    // level without a GPU pass, so it gets the same flat-colour measurement.
    await capture("whiteprobe_local_\(patch)_420v10p", windowColor: color, wantsLuma: true) { config, _ in
      config.captureDynamicRange = .hdrLocalDisplay
      config.colorSpaceName = CGColorSpace.itur_2100_PQ as CFString
      config.pixelFormat = kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
    }
  }
}

// How far above SDR white can anything go? An extended-range window is how an HDR video frame
// actually reaches the compositor, so measuring it says both whether ScreenCaptureKit passes EDR
// through unchanged and where the ceiling is. The request is a linear multiple of SDR white, so the
// prediction is the 100 cd/m2 SDR white measured above multiplied by that multiple, until the display
// headroom reported by NSScreen cuts it off.
if !liveCapture, #available(macOS 15.0, *) {
  // The wide sweep asks where the ceiling really is: 128 times SDR white would be above the 10000
  // cd/m2 PQ reference, so the run where the numbers stop tracking the request is the answer.
  let multiples: [Double] = onlyExtendedSweep
    ? [1.0, 4.0, 8.0, 16.0, 32.0, 64.0, 128.0]
    : [1.0, 1.5, 2.0, 3.0, 5.0, 8.0]

  for multiple in multiples {
    await capture("edrq_canonical_\(multiple)x_linear", windowColor: edrWhite(multiple),
      windowExtendedRange: true, wantsLuma: true) { config, _ in
      config.captureDynamicRange = .hdrCanonicalDisplay
      config.colorSpaceName = CGColorSpace.itur_2100_PQ as CFString
      config.pixelFormat = kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
    }
  }

  // The same patches through today's SDR capture, which is what a user without the HDR switch sees.
  if !onlyExtendedSweep {
    for multiple in [2.0, 5.0] {
      await capture("edrq_sdr_capture_\(multiple)x_linear", windowColor: edrWhite(multiple),
        windowExtendedRange: true, wantsLuma: true) { config, _ in
        config.pixelFormat = kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
      }
    }
  }
}

// Measure whatever is actually on the screen, with no window of our own covering it. This is the
// shape of the YouTube question: play an HDR clip, run this, and the percentiles say which luminances
// the browser put on screen and therefore what a capture could carry.
if liveCapture, #available(macOS 15.0, *) {
  await capture("live_canonical_420v10p", wantsLuma: true, wholeFrameLuma: true) { config, _ in
    config.captureDynamicRange = .hdrCanonicalDisplay
    config.colorSpaceName = CGColorSpace.itur_2100_PQ as CFString
    config.pixelFormat = kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
  }

  await capture("live_sdr_capture_420v10p", wantsLuma: true, wholeFrameLuma: true) { config, _ in
    config.pixelFormat = kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
  }
}

print("\ndone")
