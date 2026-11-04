// Exposure-invariant luma statistics for photographs of a screen.
//
// Usage: swiftc -O -o lumastats scripts/lumastats.swift && ./lumastats <img> [img...]
//
// Photos are the only input that measures light leaving a client panel, and camera gain differs between
// shots even with AE/AF locked, see docs/macos_hdr.md section 12.2. Percentiles are reported in linear
// luma over named patches; ratios between patches of the same photograph cancel that gain.
// Analyse original files: pasting an image into a chat re-encodes it to Display P3 8-bit JPEG.
// Usage: lumastats <img> [img...]
// For each image it prints linear-luma percentiles globally and inside a chosen patch,
// plus ratios, so a camera-exposure difference (a pure gain) cancels out.
import Foundation
import AppKit

func linearize(_ v: Double) -> Double {
  return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
}

// Patch as fraction of the image: x0, y0, x1, y1.
let patches: [(String, Double, Double, Double, Double)] = [
  ("wall-top", 0.02, 0.01, 0.40, 0.10),    // physical wall: pure exposure reference, no stream content
  ("keyboard", 0.06, 0.76, 0.94, 0.94),    // physical keyboard: second exposure reference
  ("video-rose", 0.07, 0.29, 0.49, 0.61),  // the HDR video window: highlights + near-black
  ("desktop-right", 0.53, 0.31, 0.96, 0.62),  // SDR desktop wallpaper (bridge/sea) as seen in the stream
  ("menu-bar", 0.06, 0.135, 0.94, 0.155),  // host menu bar strip in the stream
]

for path in CommandLine.arguments.dropFirst() {
  guard let img = NSImage(contentsOfFile: path),
        let tiff = img.tiffRepresentation,
        let rep = NSBitmapImageRep(data: tiff) else {
    print("\(path): load failed")
    continue
  }
  let w = rep.pixelsWide, h = rep.pixelsHigh
  print("== \(path)  \(w)x\(h)")

  for (name, x0, y0, x1, y1) in patches {
    var vals: [Double] = []
    vals.reserveCapacity(4096)
    var stride = max(1, Int(Double(w * h) / 400_000.0))
    var row = Int(Double(h) * y0)
    while row < Int(Double(h) * y1) {
      var col = Int(Double(w) * x0)
      while col < Int(Double(w) * x1) {
        if let c = rep.colorAt(x: col, y: row) {
          let l = 0.2126 * linearize(Double(c.redComponent)) + 0.7152 * linearize(Double(c.greenComponent)) + 0.0722 * linearize(Double(c.blueComponent))
          vals.append(l)
        }
        col += stride
      }
      row += stride
    }
    vals.sort()
    guard !vals.isEmpty else { continue }
    func p(_ f: Double) -> Double { vals[min(vals.count - 1, max(0, Int(Double(vals.count) * f)))] }
    let p5 = p(0.05), p50 = p(0.50), p95 = p(0.95), p99 = p(0.99), top = p(0.999)
    print(String(format: "  %@ p5=%.5f p50=%.5f p95=%.5f p99=%.5f max=%.5f | p99/p50=%7.2f p95/p5=%7.2f",
                 (name as NSString).padding(toLength: 12, withPad: " ", startingAt: 0), p5, p50, p95, p99, top,
                 p99 / max(p50, 1e-6), p95 / max(p5, 1e-6)))
  }
}
