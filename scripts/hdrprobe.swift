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
      print("    \(key as String): <data \(bytes.count) bytes> \(bytes.prefix(16).map { String(format: "%02x", $0) }.joined(separator: " "))")
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

  /// Prepare a printer for one capture configuration.
  init(_ label: String) {
    self.label = label
  }

  func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
    guard printed < wantedFrames else {
      return
    }

    printed += 1
    guard printed <= 3, let image = CMSampleBufferGetImageBuffer(sampleBuffer) else {
      return
    }

    let format = CVPixelBufferGetPixelFormatType(image)
    print("  [\(label)] frame \(printed): \(fourCC(format)) "
      + "\(CVPixelBufferGetWidth(image))x\(CVPixelBufferGetHeight(image)) "
      + "planes=\(CVPixelBufferGetPlaneCount(image))")
    dumpAttachments(image, "attachments")
  }
}

/// Run one capture and report what the encoder would receive.
func capture(_ label: String, configure: (SCStreamConfiguration, SCDisplay) -> Void) async {
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

  let stream = SCStream(filter: SCContentFilter(display: display, excludingWindows: []), configuration: config, delegate: nil)
  let printer = FramePrinter(label)

  do {
    try stream.addStreamOutput(printer, type: .screen, sampleHandlerQueue: nil)
    try await stream.startCapture()
  } catch {
    print("  capture setup failed: \(error)")
    return
  }

  // Give the stream a moment to deliver frames before tearing it down.
  try? await Task.sleep(for: .seconds(2.0))

  do {
    try await stream.stopCapture()
  } catch {
    print("  stopCapture: \(error)")
  }

  print("  frames delivered: \(printer.printed)")
}

describeScreens()

await capture("SDR/BGRA (what Lumen requests today)") { config, _ in
  config.pixelFormat = kCVPixelFormatType_32BGRA
}

await capture("SDR/420v10p") { config, _ in
  config.pixelFormat = kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
}

if #available(macOS 15.0, *) {
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
} else {
  print("\nHDR capture needs macOS 15 or newer")
}

print("\ndone")
