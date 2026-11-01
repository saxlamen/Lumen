#!/bin/bash
# Lumen 滾動事件記錄器（trackpad smoothness profiler）
#
# 在「被遙控的那一端」（Mac 主機）記錄實際送進系統的 scroll 事件：時間戳、事件間隔、
# 像素位移、次像素位移、scroll phase / momentum phase、以及「是誰 inject 的」（pid）。
# 之後用 lumen-scroll-compare.py 把三份記錄放在一起比較：
#
#   native   = 在這台 Mac 上直接用 touchpad 滑（原生基準）
#   lumen    = 從 Moonlight client 滑進來（Lumen 用 CGEventPost 注入）
#   rustdesk = 從 RustDesk client 滑進來
#
# 用法：
#   雙擊 lumen-scroll-profile.command → 會問你要記錄哪一種
#   ./lumen-scroll-profile.command native            # 60 秒，含節奏引導
#   ./lumen-scroll-profile.command lumen 45          # 45 秒
#   ./lumen-scroll-profile.command lumen 45 --free   # 45 秒，不要節奏引導
#   ./lumen-scroll-profile.command selftest          # 自己注入一段已知節奏，驗證腳本可用
#   ./lumen-scroll-profile.command post [n]          # 只注入 n 個事件（給 selftest 用）
#   Ctrl-C 或按 Enter → 提前結束
#
# 需要「輸入監控」/「輔助使用」權限，而且一定要在 GUI session 裡跑（雙擊 .command 即可；
# 從 SSH 跑會抓到 0 個事件，腳本會明確告訴你）。
set -uo pipefail

CACHE="$HOME/Library/Caches/lumen-scroll"
BIN="$CACHE/scrollprof"
SRC="$CACHE/scrollprof.swift"
STAMP="$CACHE/scrollprof.swift.built"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

# 記錄一律落在桌面，分析器就在旁邊（repo: tools/scroll-prof）。
OUTDIR="$HOME/Desktop/scroll-data"
ANALYZER="$SCRIPT_DIR/lumen-scroll-compare.py"

mkdir -p "$CACHE" "$OUTDIR"

cat > "$SRC" <<'SWIFT'
import Cocoa
import CoreGraphics

// MARK: - CGEventField 的數字（各 SDK 的 Swift 名稱不一致，一律用標頭裡的值）

enum F {
  static let lineAxis1: UInt32 = 11    // kCGScrollWheelEventDeltaAxis1（「行」單位）
  static let lineAxis2: UInt32 = 12    // kCGScrollWheelEventDeltaAxis2
  static let fixedAxis1: UInt32 = 93   // kCGScrollWheelEventFixedPtDeltaAxis1（16.16 次像素）
  static let fixedAxis2: UInt32 = 94
  static let isContinuous: UInt32 = 88 // kCGScrollWheelEventIsContinuous
  static let pointAxis1: UInt32 = 96   // kCGScrollWheelEventPointDeltaAxis1（像素）
  static let pointAxis2: UInt32 = 97
  static let scrollPhase: UInt32 = 99  // kCGScrollWheelEventScrollPhase（1 began / 2 changed / 4 ended / 8 cancelled）
  static let scrollCount: UInt32 = 100
  static let momentumPhase: UInt32 = 123  // 0 none / 1 begin / 2 continue / 3 end
  static let accAxis1: UInt32 = 176
  static let accAxis2: UInt32 = 175
  static let rawAxis1: UInt32 = 178
  static let rawAxis2: UInt32 = 177
  static let sourcePid: UInt32 = 41    // kCGEventSourceUnixProcessID → 誰 inject 的
  static let sourceState: UInt32 = 45  // kCGEventSourceStateID
}

let tapHid = CGEventTapLocation(rawValue: 0)!      // kCGHIDEventTap
let tapSession = CGEventTapLocation(rawValue: 1)!  // kCGSessionEventTap

// MARK: - 時間

private let timebase: mach_timebase_info_data_t = {
  var info = mach_timebase_info_data_t()
  mach_timebase_info(&info)
  return info
}()

/// mach ticks（CGEvent.timestamp 與 mach_absolute_time() 的單位）→ 奈秒
func ns(_ ticks: UInt64) -> Double {
  Double(ticks) * Double(timebase.numer) / Double(timebase.denom)
}

// MARK: - 一筆事件

struct Row {
  var level: Int       // 0 = HID tap, 1 = session tap
  var tMs: Double      // 事件時間戳（相對第一個事件）
  var recvMs: Double   // tap 收到事件的時刻
  var lagUs: Double    // 事件時間戳 → tap 收到的延遲
  var srcPid: Int64
  var srcState: Int64
  var cont: Int64
  var phase: Int64
  var momentum: Int64
  var count: Int64
  var pointY: Double
  var pointX: Double
  var fixedY: Double
  var fixedX: Double
  var lineY: Int64
  var lineX: Int64
  var rawY: Int64
  var rawX: Int64
  var accY: Int64
  var accX: Int64
  var x: Double
  var y: Double
  var flags: UInt64
}

final class Store {
  static let shared = Store()
  var rows: [Row] = []
  var counts = [0, 0]
  var firstT: Double = -1
  var startRecv: Double = 0
  var taps: [CFMachPort?] = [nil, nil]
  var running = true
  /// 0 = 尚未判斷，1 = event.timestamp 已經是奈秒，2 = event.timestamp 是 mach ticks
  var tsUnit = 0
  var firstRawStamp: UInt64 = 0
  var firstRecvTicks: UInt64 = 0
}

func field(_ event: CGEvent, _ raw: UInt32) -> Int64 {
  guard let f = CGEventField(rawValue: raw) else { return 0 }
  return event.getIntegerValueField(f)
}

func handle(_ level: Int, _ event: CGEvent) {
  let store = Store.shared
  let recvTicks = mach_absolute_time()
  let recv = ns(recvTicks)
  let rawStamp = event.timestamp

  // CGEvent.timestamp 的單位在不同 macOS/硬體上不一樣（有的已經是 ns，有的是 mach ticks），
  // 用「跟哪個參考點比較近」自動判斷，判錯會差 40 倍以上，不會误判。
  if store.tsUnit == 0 {
    store.firstRawStamp = rawStamp
    store.firstRecvTicks = recvTicks
    store.tsUnit = abs(Double(rawStamp) - recv) < abs(Double(rawStamp) - Double(recvTicks)) ? 1 : 2
  }
  let t = rawStamp == 0 ? recv : (store.tsUnit == 1 ? Double(rawStamp) : ns(rawStamp))

  if store.firstT < 0 {
    store.firstT = t
    store.startRecv = recv
  }
  let fixedY = Double(field(event, F.fixedAxis1)) / 65536.0
  let fixedX = Double(field(event, F.fixedAxis2)) / 65536.0
  let pointY = Double(field(event, F.pointAxis1))
  let pointX = Double(field(event, F.pointAxis2))
  store.rows.append(Row(
    level: level,
    tMs: (t - store.firstT) / 1_000_000.0,
    recvMs: (recv - store.startRecv) / 1_000_000.0,
    lagUs: (recv - t) / 1_000.0,
    srcPid: field(event, F.sourcePid),
    srcState: field(event, F.sourceState),
    cont: field(event, F.isContinuous),
    phase: field(event, F.scrollPhase),
    momentum: field(event, F.momentumPhase),
    count: field(event, F.scrollCount),
    pointY: pointY != 0 ? pointY : fixedY,
    pointX: pointX != 0 ? pointX : fixedX,
    fixedY: fixedY,
    fixedX: fixedX,
    lineY: field(event, F.lineAxis1),
    lineX: field(event, F.lineAxis2),
    rawY: field(event, F.rawAxis1),
    rawX: field(event, F.rawAxis2),
    accY: field(event, F.accAxis1),
    accX: field(event, F.accAxis2),
    x: Double(event.location.x),
    y: Double(event.location.y),
    flags: event.flags.rawValue
  ))
  store.counts[level] += 1
}

/// 注意：tap callback 必須是不能 capture 環境變數的 C function。
func tapCallbackHid(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                    refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
  if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
    if let tap = Store.shared.taps[0] { CGEvent.tapEnable(tap: tap, enable: true) }
    return Unmanaged.passUnretained(event)
  }
  if type == .scrollWheel { handle(0, event) }
  return Unmanaged.passUnretained(event)
}

func tapCallbackSession(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                        refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
  if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
    if let tap = Store.shared.taps[1] { CGEvent.tapEnable(tap: tap, enable: true) }
    return Unmanaged.passUnretained(event)
  }
  if type == .scrollWheel { handle(1, event) }
  return Unmanaged.passUnretained(event)
}

// MARK: - 節奏引導（三份記錄要用同一組動作才可比）

struct Stage {
  let start: Double
  let text: String
}

let stages60 = [
  Stage(start: 0, text: "準備：兩指放到 trackpad 上，目標視窗置中"),
  Stage(start: 3, text: "① 5 次短促 single flick：每次划一下就完全停下"),
  Stage(start: 15, text: "② 4 次慢速長拖：兩指按住不放，緩慢匀速從一端到另一端"),
  Stage(start: 29, text: "③ 3 次快速長 flick：划一下後手指離開，讓它自己跑到完全停止（不要按停）"),
  Stage(start: 43, text: "④ 連續小幅度滑動：像讀長網頁，盡量保持固定節奏"),
]

// MARK: - 模式

let args = CommandLine.arguments
let mode = args.count > 1 ? args[1] : "record"

func defaultsValue(_ domain: String, _ key: String) -> String {
  let p = Process()
  p.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
  p.arguments = ["read", domain, key]
  let pipe = Pipe()
  p.standardOutput = pipe
  p.standardError = Pipe()
  try? p.run()
  p.waitUntilExit()
  let data = pipe.fileHandleForReading.readDataToEndOfFile()
  let value = String(data: data, encoding: .utf8)?
    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
  return value.isEmpty ? "(unset)" : value
}

func appName(for pid: Int64) -> String {
  guard let app = NSWorkspace.shared.runningApplications.first(where: {
    Int64($0.processIdentifier) == pid
  }) else { return "(unknown)" }
  return app.localizedName ?? "(unnamed)"
}

// ---- post：注入一段已知節奏的事件（selftest 用，也可拿來驗證管線） ----
if mode == "post" {
  let n = args.count > 2 ? (Int(args[2]) ?? 40) : 40
  let hid = args.count > 3 && args[3] == "session" ? tapSession : tapHid
  for i in 0..<n {
    // 三角速度曲線：先加速再減速，節奏固定 8ms
    let shape = sin(Double(i) / Double(n) * Double.pi)
    let step = max(1, Int((shape * 12.0).rounded()))
    let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                        wheel1: Int32(step), wheel2: 0, wheel3: 0)!
    event.setIntegerValueField(CGEventField(rawValue: F.isContinuous)!, value: 1)
    event.post(tap: hid)
    Thread.sleep(forTimeInterval: 0.008)
  }
  print("已從 pid \(getpid()) 送出 \(n) 個 scroll 事件（8ms 節奏）")
  exit(0)
}

// ---- record / selftest ----
var label = "session"
var duration = 60.0
var drill = true
var selftest = (mode == "selftest")
var levels = [0, 1]  // 同時收 HID 與 session 兩層，哪層收得到用哪層

var positional: [String] = []
for argument in args.dropFirst() {
  switch argument {
  case "--free": drill = false
  case "--hid": levels = [0]
  case "--session": levels = [1]
  case "selftest": selftest = true
  case "record": break
  default: positional.append(argument)
  }
}
if selftest {
  label = "selftest"
  duration = 8
  drill = false
} else {
  if let first = positional.first { label = first }
  if positional.count > 1, let seconds = Double(positional[1]) { duration = seconds }
}

var created: [String] = []
let mask = UInt64(1 << CGEventType.scrollWheel.rawValue)
for level in levels {
  if level == 0 {
    guard let tap = CGEvent.tapCreate(tap: tapHid, place: .headInsertEventTap, options: .listenOnly,
                                      eventsOfInterest: mask, callback: tapCallbackHid, userInfo: nil) else {
      continue
    }
    Store.shared.taps[0] = tap
    CFRunLoopAddSource(CFRunLoopGetCurrent(), CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0), .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)
    created.append("HID")
  } else {
    guard let tap = CGEvent.tapCreate(tap: tapSession, place: .headInsertEventTap, options: .listenOnly,
                                      eventsOfInterest: mask, callback: tapCallbackSession, userInfo: nil) else {
      continue
    }
    Store.shared.taps[1] = tap
    CFRunLoopAddSource(CFRunLoopGetCurrent(), CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0), .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)
    created.append("session")
  }
}
guard !created.isEmpty else {
  print("❌ 建不起 event tap（權限或 GUI session 問題）")
  print("   1) 系統設定 → 隱私與安全性 → 輸入監控：加入「終端機」")
  print("   2) 系統設定 → 隱私與安全性 → 輔助使用：加入「終端機」")
  print("   3) 必須在登入的桌面環境執行（雙擊本 .command）；純 SSH session 收不到事件")
  exit(2)
}

let formatter = DateFormatter()
formatter.dateFormat = "yyyyMMdd-HHmmss"
let stamp = formatter.string(from: Date())
let outPath = ("~/Desktop/scroll-data/\(label)_\(stamp).csv" as NSString).expandingTildeInPath

print("記錄中：label=\(label)  時間軸 tap=\(created.joined(separator: "+"))  \(Int(duration)) 秒")
if drill {
  print("照著下面跳出來的節奏滑，三份記錄才可比。")
} else {
  print("自由記錄模式：想怎麼滑就怎麼滑。")
}
print("按 Enter 或 Ctrl-C 可提前結束。\n")

var nextStage = 0
var warnedEmpty = false
var posted = false
let begin = Date()

func finish(_ reason: String) {
  guard Store.shared.running else { return }
  Store.shared.running = false
  for tap in Store.shared.taps { if let tap { CGEvent.tapEnable(tap: tap, enable: false) } }

  var lines: [String] = []
  lines.append("# label=\(label)")
  let iso = DateFormatter()
  iso.locale = Locale(identifier: "en_US_POSIX")
  iso.dateFormat = "yyyy-MM-dd'T'HH:mm:ssXXXXX"
  lines.append("# started=\(iso.string(from: begin))")
  lines.append("# duration_s=\(String(format: "%.1f", Date().timeIntervalSince(begin)))")
  lines.append("# drill=\(drill ? 1 : 0)")
  lines.append("# taps=\(created.joined(separator: "+"))")
  lines.append("# host=\(Host.current().localizedName ?? "?")")
  lines.append("# os=macOS \(ProcessInfo.processInfo.operatingSystemVersion)")
  lines.append("# self_pid=\(getpid())")
  let unitName = Store.shared.tsUnit == 1 ? "ns" : (Store.shared.tsUnit == 2 ? "mach-ticks" : "unknown")
  lines.append("# ts_unit=\(unitName)")
  lines.append("# timebase=\(timebase.numer)/\(timebase.denom)")
  lines.append("# ts_first=\(Store.shared.firstRawStamp)|recv_first_ticks=\(Store.shared.firstRecvTicks)")
  if let app = NSWorkspace.shared.frontmostApplication {
    lines.append("# front_app=\(app.localizedName ?? "?")")
    lines.append("# front_bundle=\(app.bundleIdentifier ?? "?")")
  }
  for screen in NSScreen.screens {
    lines.append("# display=\(screen.localizedName)|\(Int(screen.maximumFramesPerSecond))Hz|\(Int(screen.frame.width))x\(Int(screen.frame.height))")
  }
  for (domain, key) in [("-g", "com.apple.trackpad.scaling"), ("-g", "com.apple.mouse.scaling"),
                        ("-g", "com.apple.swipescrolldirection")] {
    lines.append("# pref=\(key)=\(defaultsValue(domain, key))")
  }
  for pid in Set(Store.shared.rows.map { $0.srcPid }).sorted() {
    lines.append("# src_pid=\(pid)|\(appName(for: pid))")
  }
  lines.append("level,t_ms,recv_ms,lag_us,src_pid,src_state,continuous,phase,momentum,scroll_count,"
               + "point_y,point_x,fixed_y,fixed_x,line_y,line_x,raw_y,raw_x,acc_y,acc_x,x,y,flags")
  for row in Store.shared.rows {
    lines.append(String(format: "%d,%.3f,%.3f,%.1f,%d,%d,%d,%d,%d,%d,%.4f,%.4f,%.4f,%.4f,%d,%d,%d,%d,%d,%d,%.1f,%.1f,%llu",
                        row.level, row.tMs, row.recvMs, row.lagUs, row.srcPid, row.srcState, row.cont, row.phase,
                        row.momentum, row.count, row.pointY, row.pointX, row.fixedY, row.fixedX, row.lineY, row.lineX,
                        row.rawY, row.rawX, row.accY, row.accX, row.x, row.y, row.flags))
  }
  let text = lines.joined(separator: "\n") + "\n"
  try? text.write(toFile: outPath, atomically: true, encoding: .utf8)

  print("\n\(reason)，記錄結束。")
  print("  HID tap    : \(Store.shared.counts[0]) 個事件")
  print("  session tap: \(Store.shared.counts[1]) 個事件")
  let byPid = Dictionary(grouping: Store.shared.rows, by: { $0.srcPid }).mapValues { $0.count }
  for (pid, n) in byPid.sorted(by: { $0.value > $1.value }) {
    print("  inject 來源: pid \(pid) = \(appName(for: pid)) → \(n) 個")
  }
  print("  檔案: \(outPath)")
  if Store.shared.rows.isEmpty {
    if selftest {
      print("\n❌ selftest 連自己注入的事件都收不到 → 這個執行環境收不到 event tap。")
      print("   • launchctl managername 要是 Aqua（真的登入的桌面 session），Background 收不到")
      print("   • 系統設定 → 隱私與安全性 → 輸入監控 與 輔助使用：加入「終端機」")
      print("   • 最穩的做法：在 Mac 桌面上雙擊 lumen-scroll-profile.command")
    } else {
      print("\n⚠️ 一個事件都沒收到。常見原因：")
      print("   • 從 SSH 跑（launchctl managername = Background）→ 改成雙擊 .command")
      print("   • 沒給「輸入監控」權限")
      print("   • 這 \(Int(duration)) 秒內沒有人真的在滑")
      print("   先跑一次：./lumen-scroll-profile.command selftest")
    }
  } else if selftest {
    print("\n✅ selftest 收到 \(Store.shared.rows.count) 個事件（8ms 注入節奏），管線可用，可以開始正式記錄。")
  }
  exit(0)
}

let timer = DispatchSource.makeTimerSource(queue: .main)
timer.schedule(deadline: .now(), repeating: 0.2)
timer.setEventHandler {
  guard Store.shared.running else { return }
  let elapsed = Date().timeIntervalSince(begin)

  if drill {
    while nextStage < stages60.count && elapsed >= stages60[nextStage].start {
      print("\n▶ \(stages60[nextStage].text)")
      nextStage += 1
    }
  }
  if elapsed > 15 && Store.shared.rows.isEmpty && !warnedEmpty {
    warnedEmpty = true
    print("\n⚠️ 15 秒了還是 0 個事件——確認你在桌面環境跑（雙擊 .command）、有在滑、且已給輸入監控權限。")
  }
  let left = max(0, duration - elapsed)
  print(String(format: "\r\033[K⏳ %.1fs / %.0fs   hid=%d session=%d   （剩 %.0fs）",
               elapsed, duration, Store.shared.counts[0], Store.shared.counts[1], left))

  if selftest && !posted && elapsed >= 1.5 {
    posted = true
    let child = Process()
    child.executableURL = Bundle.main.executableURL
    child.arguments = ["post", "120"]
    try? child.run()
  }
  if elapsed >= duration { finish(selftest ? "selftest 完成" : "時間到") }
}
timer.resume()

if isatty(0) == 1 {
  let stdinSource = DispatchSource.makeReadSource(fileDescriptor: 0, queue: .main)
  stdinSource.setEventHandler { finish("你按了 Enter") }
  stdinSource.setCancelHandler {}
  stdinSource.resume()
}

let signalSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
signal(SIGINT, SIG_IGN)
signalSource.setEventHandler { finish("Ctrl-C") }
signalSource.resume()

RunLoop.main.run()
SWIFT

if [ ! -x "$BIN" ] || ! cmp -s "$SRC" "$STAMP"; then
  echo "編譯中（第一次約 10–20 秒）..."
  if ! /usr/bin/swiftc -O -o "$BIN" "$SRC" 2>"$CACHE/build.log"; then
    echo "編譯失敗："
    cat "$CACHE/build.log"
    exit 1
  fi
  cp "$SRC" "$STAMP"
fi

# 從 SSH 跑的話幾乎一定收不到事件，先講清楚。
if [ $# -eq 0 ]; then
  printf "要記錄哪一種？native / lumen / rustdesk / selftest [native]: "
  read -r ASK || ASK=""
  [ -z "${ASK:-}" ] && ASK="native"
  set -- "$ASK"
fi

if [ "${1:-}" != "post" ]; then
  SESSION_KIND="$(launchctl managername 2>/dev/null || echo unknown)"
  if [ "$SESSION_KIND" != "Aqua" ]; then
    echo "⚠️ 目前的執行環境是 ${SESSION_KIND}（不是桌面 GUI session），event tap 會收到 0 個事件。"
    echo "   請在 Mac 桌面上雙擊這個 .command；或試試："
    echo "     sudo launchctl asuser \$(id -u) '$BIN' ${*:-record}"
    echo
  fi
fi

"$BIN" "$@"
STATUS=$?

# 記錄完順帶跑一次分析（如果分析器在的话）
if [ "$STATUS" = 0 ] && [ -f "$ANALYZER" ] && [ "${1:-}" != "post" ]; then
  LATEST="$(ls -t "$OUTDIR"/*.csv 2>/dev/null | head -1)"
  if [ -n "${LATEST:-}" ]; then
    echo
    python3 "$ANALYZER" --gestures "$LATEST" || true
  fi
fi
exit "$STATUS"
