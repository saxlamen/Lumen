#!/bin/bash
# Lumen 動態內容產生器
#
# 雙擊執行：會在「每一顆螢幕」上蓋一個全螢幕的黑色視窗，裡面有持續移動的方塊、
# 一道掃過的色條，以及每 1/60 秒都在變的時間/帧計數。這樣 ScreenCaptureKit 每一帧
# 都會看到真實內容變化，不會走到「超時重編上一帧」的路徑，量出來的 encode rate /
# encoder output latency / Frame processing latency 才是有效的。
#
# 用法：
#   雙擊            → 跑 75 秒
#   終端機執行      → ./lumen-motion-test.command 120   （跑 120 秒）
#   Ctrl-C          → 提前結束
set -uo pipefail

DURATION="${1:-75}"
CACHE="$HOME/Library/Caches/lumen-motion"
BIN="$CACHE/motion"
SRC="$CACHE/motion.swift"
STAMP="$CACHE/motion.swift.built"

mkdir -p "$CACHE"

cat > "$SRC" <<'SWIFT'
import Cocoa

/// A view that repaints itself continuously so the captured display always changes.
final class MotionView: NSView {
  private var start: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()
  private var frames: Int = 0

  override var isFlipped: Bool { true }

  override func draw(_ dirtyRect: NSRect) {
    frames += 1
    let t = CFAbsoluteTimeGetCurrent() - start
    let w = bounds.width
    let h = bounds.height

    NSColor(calibratedHue: CGFloat((t * 0.05).truncatingRemainder(dividingBy: 1)),
            saturation: 0.30, brightness: 0.20, alpha: 1).setFill()
    bounds.fill()

    // Sweeping bar: guarantees pixels change across the whole frame.
    let barW = max(24, w * 0.02)
    let barX = w * (t.truncatingRemainder(dividingBy: 2.0) / 2.0) - barW
    NSColor(calibratedRed: 1, green: 0.62, blue: 0.10, alpha: 1).setFill()
    NSRect(x: barX, y: 0, width: barW, height: h).fill()

    // Moving square.
    let side = min(220, h * 0.25)
    let travel = max(1, w - side)
    let x = travel * 0.5 * (1.0 + sin(t * 1.7))
    NSColor.white.setFill()
    NSRect(x: x, y: (h - side) / 2, width: side, height: side).fill()

    // Text that changes every frame.
    let label = String(format: "MOTION  %.2fs   frame %d", t, frames)
    let attrs: [NSAttributedString.Key: Any] = [
      .font: NSFont.monospacedDigitSystemFont(ofSize: max(24, min(64, w / 12)), weight: .bold),
      .foregroundColor: NSColor.black,
    ]
    NSAttributedString(string: label, attributes: attrs).draw(at: NSPoint(x: 40, y: 40))
    NSAttributedString(string: "Lumen latency test - do not touch", attributes: [
      .font: NSFont.systemFont(ofSize: max(16, min(30, w / 26))),
      .foregroundColor: NSColor.white,
    ]).draw(at: NSPoint(x: 40, y: h - 90))
  }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
  private var windows: [NSWindow] = []
  private var views: [MotionView] = []
  private var timer: Timer?

  func applicationDidFinishLaunching(_ note: Notification) {
    let duration = CommandLine.arguments.count > 1
      ? (Double(CommandLine.arguments[1]) ?? 75)
      : 75

    for screen in NSScreen.screens {
      let win = NSWindow(contentRect: screen.frame, styleMask: [.borderless],
                         backing: .buffered, defer: false)
      win.isOpaque = true
      win.hasShadow = false
      win.level = .floating
      win.ignoresMouseEvents = true
      win.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
      win.backgroundColor = .black
      let view = MotionView(frame: NSRect(origin: .zero, size: screen.frame.size))
      win.contentView = view
      win.setFrame(screen.frame, display: true)
      win.orderFrontRegardless()
      windows.append(win)
      views.append(view)
      FileHandle.standardError.write("screen frame: \(screen.frame)\n".data(using: .utf8)!)
    }

    timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { _ in
      for view in self.views { view.needsDisplay = true }
    }

    DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
      NSApp.terminate(nil)
    }
  }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
SWIFT

if [ ! -x "$BIN" ] || ! cmp -s "$SRC" "$STAMP"; then
  echo "失令中（第一次編譯約 10–20 秒）..."
  if ! /usr/bin/swiftc -O -o "$BIN" "$SRC"; then
    echo "失令失败：找不到 swiftc（需要 Xcode Command Line Tools）。"
    exit 1
  fi
  cp "$SRC" "$STAMP"
fi

echo "請先確認 Moonlight 已連上，然後開始。跑 ${DURATION} 秒。"
date +"開始 %H:%M:%S"
"$BIN" "$DURATION"
date +"結束 %H:%M:%S"
echo "跑完了，跟我說一聲（或直接告我開始/結束的時刻）。"
