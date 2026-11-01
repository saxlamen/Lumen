#!/usr/bin/env python3
"""只看慣性的簡易檢測：讀一份 lumen 記錄，印一張表格加一句判定。

用法：
  ./lumen-inertia.py                      # 自動取最新一份 lumen_*.csv
  ./lumen-inertia.py scroll-data/xx.csv   # 指定檔案

指標全部從「系統實際收到的事件」（CGEvent tap）算，不靠 Lumen 自己的 log。
卡頓會去對 ~/.config/sunshine/sunshine.log 裡的 Scroll census，區分是 client 沒包
還是 Lumen 沒注入。
"""
from __future__ import annotations

import csv
import glob
import os
import re
import statistics as st
import sys
from collections import Counter

CSV_GLOB = os.path.expanduser("~/Desktop/scroll-data/lumen_*.csv")
LOG_GLOB = os.path.expanduser("~/.config/sunshine/sunshine.log*")

GOOD = "✅"
WARN = "⚠️"


def load_events(path):
    """回傳單一层（事件較多的那一層）的事件序列，位移一律換算成像素。"""
    with open(path, encoding="utf-8", errors="replace") as fh:
        body = [line for line in fh if not line.startswith("#")]
    rows = list(csv.DictReader(body))
    if not rows:
        return []
    level = Counter(r["level"] for r in rows).most_common(1)[0][0]
    events = []
    for r in rows:
        if r.get("level") != level:
            continue
        try:
            point = float(r["point_y"])
            fixed = float(r["fixed_y"])
            # 用事件自己的時間戳：tap 會成批投递，recv_ms 會偽造成 <4ms 的「同瞬間簇」。
            try:
                t = float(r["t_ms"])
            except (ValueError, TypeError, KeyError):
                t = float(r["recv_ms"])
        except (ValueError, TypeError, KeyError):
            continue
        # fixed-point 欄位是 line 單位（1 line = 10px），point 欄位只有整數像素，
        # 所以取兩者較大者才是這個事件真正的像素位移。
        pixels = point if abs(point) >= abs(fixed) * 10 else fixed * 10
        events.append({"t": t, "px": pixels})
    return events


def started_clock_ms(path):
    """CSV 檔頭的 # started=... → 当天過了幾毫秒（用来對 census 的時刻）。"""
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            for line in fh:
                if not line.startswith("#"):
                    break
                m = re.search(r"started=\d{4}-\d\d-\d\dT(\d\d):(\d\d):(\d\d)", line)
                if m:
                    h, mi, s = m.groups()
                    return ((int(h) * 60 + int(mi)) * 60 + int(s)) * 1000
    except OSError:
        pass
    return None


def load_census():
    """由 log 取出每個 census 窗口的 (時刻 ms, client 最大空窗, 注入最大空窗)。"""
    out = []
    for path in glob.glob(LOG_GLOB):
        try:
            with open(path, encoding="utf-8", errors="replace") as fh:
                for line in fh:
                    if "Scroll census [" not in line:
                        continue
                    m = re.search(
                        r"(\d\d):(\d\d):(\d\d)\.(\d{3}).*max_gap=([\d.]+)ms \| injected events=\d+ avg_gap=[\d.]+ms max_gap=([\d.]+)ms",
                        line,
                    )
                    if m:
                        h, mi, s, msec, client_max, inj_max = m.groups()
                        t = ((int(h) * 60 + int(mi)) * 60 + int(s)) * 1000 + int(msec)
                        out.append((t, float(client_max), float(inj_max)))
        except OSError:
            continue
    return sorted(out)


def tails_of(events, break_gap=400.0):
    """以 >break_gap 的空隙切段，段尾即是放手後的慣性段（取每段最後一個事件前的連續段）。"""
    segments, cur = [], [events[0]]
    for a, b in zip(events, events[1:]):
        if b["t"] - a["t"] > break_gap:
            segments.append(cur)
            cur = [b]
        else:
            cur.append(b)
    segments.append(cur)
    return [s for s in segments if len(s) >= 6]


def analyze(events, census, start_ms):
    """尾巴統計 + 中段空窗歸因。start_ms 為記錄開始的時刻，用来對 census 窗口。"""
    tails = [s for s in tails_of(events) if sum(abs(e["px"]) for e in s) > 100]
    rows = []
    for tail in tails:
        gaps = [b["t"] - a["t"] for a, b in zip(tail, tail[1:])]
        if not gaps:
            continue
        rows.append({
            "cadence": st.median(gaps),
            "cluster": sum(1 for g in gaps if g < 4),
            "gaps": len(gaps),
            "distance": sum(abs(e["px"]) for e in tail),
            "length": tail[-1]["t"] - tail[0]["t"],
        })

    # 只算「還在動的時候突然停住」：兩側都在位移、且空窗前本來是連續的。手勢之間本該有的停顿不算。
    stalls = []
    for i in range(1, len(events)):
        gap = events[i]["t"] - events[i - 1]["t"]
        if not 250.0 < gap <= 1200.0:
            continue
        before = abs(events[i - 1]["px"]) > 1.0 and abs(events[i - 2]["px"]) > 1.0 if i >= 2 else False
        after = abs(events[i]["px"]) > 1.0
        hot = events[i - 1]["t"] - events[i - 2]["t"] < 50.0 if i >= 2 else False
        if before and after and hot:
            stalls.append((gap, events[i]["t"]))

    verdicts = []
    for gap, at in stalls:
        when = (start_ms + at) if start_ms is not None else None
        match = None
        if when is not None:
            for clock, client_max, injected_max in census:
                if abs(clock - when) > 3000:
                    continue
                # client 停包會把注入端一起撐開；只有注入端較大才算 Lumen 的問題。
                if 0.7 * gap <= client_max <= 1.4 * gap:
                    match = (client_max, injected_max)
                    break
        if match:
            verdicts.append((gap, "client 停包", match[0], match[1]))
        else:
            verdicts.append((gap, "census 對應不到", None, None))

    subpixel = sum(1 for e in events if abs(e["px"] % 1.0) > 0.02)
    return rows, stalls, verdicts, subpixel


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else (max(glob.glob(CSV_GLOB), key=os.path.getmtime) if glob.glob(CSV_GLOB) else None)
    if not path or not os.path.exists(path):
        print("找不到 lumen 記錄 CSV。")
        return 1
    events = load_events(path)
    if len(events) < 30:
        print(f"{os.path.basename(path)}：事件太少（{len(events)}），請重收。")
        return 1
    census = load_census()
    tails, stalls, verdicts, subpixel = analyze(events, census, started_clock_ms(path))

    span = (events[-1]["t"] - events[0]["t"]) / 1000.0
    print(f"\n慣性檢測  {os.path.basename(path)}  {span:.0f}s  {len(events)} 個事件\n")
    print(f"{'指標':<22}{'實測':<26}{'判讀'}")
    print("-" * 74)

    if tails:
        cad = st.median(t["cadence"] for t in tails)
        note = "120Hz 等級 ✅" if cad <= 11 else "低於 90Hz，會逐格"
        print(f"{'尾巴節奏':<22}{f'median {cad:.1f}ms':<26}{note}")
        cluster = sum(t["cluster"] for t in tails)
        total = sum(t["gaps"] for t in tails)
        pct = 100.0 * cluster / total if total else 0.0
        note = GOOD + " 無補吐" if pct < 3 else "多半是 packet 與滑行的交接，同一次刷新會被合成一步"
        print(f"{'同瞬間簇（<4ms）':<22}{f'{cluster}/{total}  {pct:.1f}%':<26}{note}")
        dist = st.median(t["distance"] for t in tails)
        length = st.median(t["length"] for t in tails)
        # 只給參考：連續甩動會被併成一段，而且絕對值會被原生來源的單位差放大；
        # 要認真比較距離請用 lumen-scroll-compare.py，它會先校正 fixed 欄的單位。
        print(f"{'滑行段（參考）':<21}{f'median {dist:.0f}px / {length/1000:.2f}s':<26}{len(tails)} 段，單位未校正")
    else:
        print(f"{'尾巴':<22}{'找不到 >100px 的尾巴':<26}{WARN + ' 請做 6 次快速甩動'}")

    frac = 100.0 * subpixel / len(events)
    print(f"{'帶小數（sub-pixel）':<22}{f'{frac:.1f}%':<26}{GOOD + ' 次像素生效' if frac > 20 else WARN + ' 疑似仍是整數像素'}")

    if stalls:
        worst = max(stalls)[0]
        print(f"{'中段空窗':<22}{f'{len(stalls)} 次，最大 {worst:.0f}ms':<26}", end="")
        if verdicts and all(v[1] == "client 停包" for v in verdicts):
            print(f"{WARN} client 端停包，非 Lumen")
        else:
            print(f"{WARN} 需查 census 歸因")
        for gap, why, cmax, imax in verdicts[:3]:
            detail = f"（client max {cmax:.0f}ms／injected max {imax:.0f}ms）" if cmax else ""
            print(f"  {gap:>6.0f}ms 空窗 → {why}{detail}")
    else:
        print(f"{'中段空窗':<22}{'無 250ms 以上空窗':<26}{GOOD}")

    ok = bool(tails) and st.median(t["cadence"] for t in tails) <= 11 and frac > 20 and not stalls
    print("\n判定：" + ("慣性路徑正常（節奏 8ms、次像素、無空窗）。" if ok else "慣性路徑大致正常，但上面標 ⚠️ 的項目要處理。"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
