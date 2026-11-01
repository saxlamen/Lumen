#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
lumen-scroll-trace.py — 解析 Lumen 的 per-packet trace，並在離端重放候補的 pacing 演算法。

trace 需要 LUMEN_SCROLL_DIAGNOSTICS=trace（放在 LaunchAgent plist 的 EnvironmentVariables），
會輸出兩類行：
  macOS scroll trace: input  phase=none dy=-41 dx=0 interval=25.1ms velocity_y=... mode=host_inertia
  macOS scroll trace: output phase=0 momentum_phase=0 dy=-41 dx=0

input 行 = 從 client 來的 scroll packet（已經換算成 pixel，尚未注入）
output 行 = 實際 CGEventPost 出去的事件（包含 Lumen 慣性迴圈自己加的）

用途一：看清楚 client packet 到底是不是「爆發式」抵達（burst + 空隙）。
用途二：把 input 序列当作輸入，離端模擬不同 latency target 的 leaky-bucket pacing，
        比較静帧% / Δv p95 / 額外延遲，先挑好參數再上機測。

用法：
  python3 lumen-scroll-trace.py                 # 解析最近一段 trace 並跑離端模擬
  python3 lumen-scroll-trace.py --since 10:55   # 只看這個時刻之後
  python3 lumen-scroll-trace.py --selftest      # 用合成的爆發流量驗證模擬器
"""

import argparse
import datetime as dt
import math
import os
import re
import statistics as st
import sys

GOOD = "\u2705"
WARN = "\u26a0\ufe0f"

LOG_PATH = os.path.expanduser("~/.config/sunshine/sunshine.log")
IN_RE = re.compile(r"\[(\d{4}-\d\d-\d\d) (\d\d:\d\d:\d\d)\.(\d{3})\].*scroll trace: input(?: phase=\S+)? dy=(-?\d*\.?\d*) dx=(-?\d*\.?\d*) interval=([\d.]+)ms")
OUT_RE = re.compile(r"\[(\d{4}-\d\d-\d\d) (\d\d:\d\d:\d\d)\.(\d{3})\].*scroll trace: output(?: phase=(\S+))?(?: momentum_phase=(\S+))? dy=(-?\d*\.?\d*) dx=(-?\d*\.?\d*)")

EDGES = [4, 8, 12, 16, 25, 33, 50]


def bucket(gap_ms):
    for i, edge in enumerate(EDGES):
        if gap_ms < edge:
            return i
    return len(EDGES)


def hist_line(gaps, label):
    if not gaps:
        return f"  {label:<12} (無)"
    counts = [0] * (len(EDGES) + 1)
    for g in gaps:
        counts[bucket(g)] += 1
    total = len(gaps)
    cells = "/".join(str(c) for c in counts)
    return (f"  {label:<12} {cells}   n={total} median={st.median(gaps):6.1f}ms "
            f"p95={sorted(gaps)[min(total - 1, int(total * .95))]:6.1f}ms")


def ms_of(date, time, msec):
    base = dt.datetime.strptime(date + " " + time, "%Y-%m-%d %H:%M:%S")
    return base.timestamp() * 1000.0 + int(msec)


def parse(path, since):
    inputs, outputs = [], []
    with open(path, encoding="utf-8", errors="replace") as fh:
        for line in fh:
            mi, mo = IN_RE.search(line), OUT_RE.search(line)
            if not mi and not mo:
                continue
            m = mi or mo
            t = ms_of(m.group(1), m.group(2), m.group(3))
            if since and m.group(2) < since:
                continue
            if mi:
                inputs.append({"t": t, "dy": float(mi.group(4)), "dx": float(mi.group(5)), "interval": float(mi.group(6))})
            else:
                outputs.append({"t": t, "dy": float(mo.group(6)), "dx": float(mo.group(7)),
                                "phase": mo.group(4), "momentum": mo.group(5)})
    return inputs, outputs


def bursts_of(events, burst_gap=12.0):
    """把間隔 < burst_gap 的事件併成一個 burst。"""
    groups, cur = [], []
    for i, ev in enumerate(events):
        if cur and ev["t"] - cur[-1]["t"] >= burst_gap:
            groups.append(cur)
            cur = []
        cur.append(ev)
    if cur:
        groups.append(cur)
    return groups


def gesture_slices(inputs, break_gap=400.0):
    """按 >break_gap 的空隙切出手勢，避免手勢間的長空档污染指標。"""
    slices, cur = [], []
    for ev in inputs:
        if cur and ev["t"] - cur[-1]["t"] > break_gap:
            slices.append(cur)
            cur = []
        cur.append(ev)
    if cur:
        slices.append(cur)
    return [s for s in slices if len(s) >= 4]


def simulate(packets, frame_ms=8.0, target_latency=45.0, gain=0.35, release_ms=90.0,
             friction=5.5, min_velocity=12.0, max_velocity=2800.0, velocity_window=120.0):
    """模拟 leaky-bucket pacing：packet 先进 pending，每个 frame 以平滑速度排空。

    控制律：step = velocity*frame + (pending - velocity*target_latency) * gain
    即「按平滑速度推进，同时把缓冲深度拉回 target_latency 对应的像素数」。缓冲深度就是
    额外延迟，所以 target_latency 直接是延迟预算；爆发抵达时不会一次吐出，burst 空隙里
    靠缓冲继续推进 → 静帧消失。
    返回 (输出事件, 每次输出当时的缓冲深度 ms, 排出总像素, 输入总像素)。
    """
    if not packets:
        return [], [], 0.0, 0.0
    t = packets[0]["t"]
    pending = 0.0
    velocity = 0.0
    direction = 1
    recent = []
    last_packet_t = t
    next_packet = 0
    outputs = []
    depths = []
    total_in = sum(abs(p["dy"]) for p in packets)

    end_t = packets[-1]["t"] + 1600.0
    while t <= end_t:
        while next_packet < len(packets) and packets[next_packet]["t"] <= t:
            packet = packets[next_packet]
            pixels = abs(packet["dy"])
            if pixels:
                pending += pixels
                direction = 1 if packet["dy"] >= 0 else -1
                recent.append((packet["t"], pixels))
                last_packet_t = packet["t"]
            next_packet += 1

        recent = [r for r in recent if t - r[0] <= velocity_window]
        if recent:
            span = max(24.0, t - recent[0][0])
            velocity = min(sum(px for _, px in recent) / (span / 1000.0), max_velocity)

        quiet = t - last_packet_t
        if pending > 0.0 and velocity > min_velocity:
            setpoint = velocity * target_latency / 1000.0
            step = velocity * frame_ms / 1000.0 + (pending - setpoint) * gain
            step = max(0.0, min(pending, step))
            if step >= 1.0:
                outputs.append({"t": t, "dy": direction * step, "source": "paced"})
                depths.append(pending / velocity * 1000.0 if velocity > 0 else 0.0)
                pending -= step
        elif pending > 0.0:
            step = min(pending, 8.0)  # 低速残量直接排出，避免结尾卡住
            outputs.append({"t": t, "dy": direction * step, "source": "flush"})
            pending -= step
        elif quiet > release_ms and velocity > min_velocity:
            velocity *= math.exp(-friction * frame_ms / 1000.0)
            step = velocity * frame_ms / 1000.0
            if step >= 1.0:
                outputs.append({"t": t, "dy": direction * step, "source": "inertia"})
            else:
                velocity = 0.0
        t += frame_ms

    total_out = sum(abs(o["dy"]) for o in outputs)
    return outputs, depths, total_out, total_in

def window_metrics(outputs, packets, frame_ms=16.7, activity_gap=400.0):
    """按顯示帧窗口統計：静帧%、Δv p95、單帧位移。"""
    if len(outputs) < 8:
        return None
    total_span = outputs[-1]["t"] - outputs[0]["t"]
    windows = int(total_span / frame_ms) + 1
    disp = [0.0] * windows
    for o in outputs:
        disp[min(int((o["t"] - outputs[0]["t"]) / frame_ms), windows - 1)] += o["dy"]
    # 只看有活動的窗口區段
    active_lo = min(int((p["t"] - outputs[0]["t"]) / frame_ms) for p in packets)
    active_hi = max(int((p["t"] - outputs[0]["t"]) / frame_ms) for p in packets)
    seg = disp[max(0, active_lo):max(0, active_hi) + 1]
    if len(seg) < 4:
        return None
    static = sum(1 for d in seg if abs(d) < 0.5) / len(seg) * 100.0
    vel = [d / frame_ms * 1000.0 for d in seg]
    dv = sorted(abs(vel[i] - vel[i - 1]) for i in range(1, len(vel)))
    return {"static": static, "dv95": dv[int(len(dv) * .95)], "dvmax": dv[-1],
            "median_disp": st.median(abs(d) for d in seg), "max_disp": max(abs(d) for d in seg),
            "frames": len(seg)}


def selftest():
    """合成：每 50ms 一個 burst、每個 burst 3 個 packet、每 packet 25px。"""
    packets, t = [], 0.0
    for b in range(40):
        for k in range(3):
            packets.append({"t": t, "dy": -25})
            t += 3.0
        t += 47.0
    print("合成輸入：40 個 burst × 3 packet × 25px，burst 週期 50ms，共 3000px")
    run_compare(packets)


def run_compare(packets):
    print(f"  {'模式':<22}{'静帧%':>8}{'Δv p95':>9}{'Δv max':>9}{'中位px/帧':>10}{'最大px/帧':>10}"
          f"{'延迟p50':>9}{'延迟p95':>9}{'距离误差':>9}")
    immediate = [{"t": p["t"], "dy": p["dy"]} for p in packets]
    metrics = window_metrics(immediate, packets)
    if metrics:
        print(f"  {'immediate（现行）':<20}{metrics['static']:>8.1f}{metrics['dv95']:>9.0f}{metrics['dvmax']:>9.0f}"
              f"{metrics['median_disp']:>10.1f}{metrics['max_disp']:>10.1f}{'0':>9}{'0':>9}{'0%':>9}")
    for target in (24.0, 45.0, 70.0, 100.0):
        outputs, depths, total_out, total_in = simulate(packets, target_latency=target)
        metrics = window_metrics(outputs, packets)
        if not metrics or not depths:
            continue
        ds = sorted(depths)
        err = (total_out - total_in) / total_in * 100.0 if total_in else 0.0
        print(f"  {'paced latency=' + str(int(target)):<20}{metrics['static']:>8.1f}{metrics['dv95']:>9.0f}"
              f"{metrics['dvmax']:>9.0f}{metrics['median_disp']:>10.1f}{metrics['max_disp']:>10.1f}"
              f"{ds[int(len(ds)*.5)]:>9.0f}{ds[int(len(ds)*.95)]:>9.0f}{err:>8.1f}%")


def main():
    ap = argparse.ArgumentParser(description="Lumen scroll trace 解析 + pacing 离线模拟")
    ap.add_argument("--log", default=LOG_PATH)
    ap.add_argument("--since", help="只看这个时刻之后，例如 10:55 或 10:55:30")
    ap.add_argument("--selftest", action="store_true", help="用合成的爆发流量验证模拟器")
    args = ap.parse_args()

    if args.selftest:
        selftest()
        return 0
    if not os.path.exists(args.log):
        print(f"找不到 {args.log}")
        return 1

    since = None
    if args.since:
        since = args.since if len(args.since) > 5 else args.since + ":00"
    inputs, outputs = parse(args.log, since)
    if len(inputs) < 5:
        print("trace 行不足（需要 LUMEN_SCROLL_DIAGNOSTICS=trace，并从 client 滑动几秒）。")
        return 1

    print(f"input packets={len(inputs)}  output events={len(outputs)}  "
          f"span={(inputs[-1]['t'] - inputs[0]['t']) / 1000.0:.1f}s")

    gaps = [b["t"] - a["t"] for a, b in zip(inputs, inputs[1:]) if b["t"] - a["t"] < 400]
    print("\n── client packet 抵达节奏（bucket ms：<4/4-8/8-12/12-16/16-25/25-33/33-50/>50）")
    print(hist_line(gaps, "client"))
    if outputs:
        out_gaps = [b["t"] - a["t"] for a, b in zip(outputs, outputs[1:]) if b["t"] - a["t"] < 400]
        print(hist_line(out_gaps, "injected"))

    print("\n── burst 结构（<12ms 视为同一 burst）")
    groups = bursts_of(inputs)
    if groups:
        sizes = [len(g) for g in groups]
        periods = [groups[i + 1][0]["t"] - groups[i][0]["t"] for i in range(len(groups) - 1)]
        holes = [groups[i + 1][0]["t"] - groups[i][-1]["t"] for i in range(len(groups) - 1)]
        print(f"  burst 数={len(groups)}  每 burst 平均 {st.mean(sizes):.2f} 个 packet（max {max(sizes)}）"
              f"  每 burst 位移中位 {st.median(sum(abs(p['dy']) for p in g) for g in groups):.0f}px")
        if periods:
            print(f"  burst 周期：median={st.median(periods):.1f}ms  "
                  f"p95={sorted(periods)[int(len(periods) * .95)]:.1f}ms")
        if holes:
            print(hist_line(holes, "burst 间隙"))

    if outputs and inputs:
        matched = sum(1 for o in outputs if any(abs(o["t"] - p["t"]) < 4 and abs(abs(o["dy"]) - abs(p["dy"])) < 3 for p in inputs))
        print(f"\n  output 可对应到 packet 的：{matched}/{len(outputs)} → Lumen 自己加的事件 {len(outputs) - matched} 个")

    # 放手窗口：最後一個 packet 到第一個慣性事件之間畫面是完全凍結的，使用者報的「卡一下」就是它。
    print("\n── 放手凍結窗口（最後一個 packet → 第一個慣性事件）")
    tails = []
    for s in gesture_slices(inputs):
        last = s[-1]
        after = [o for o in outputs if o["t"] > last["t"] + 1.0]
        if len(after) < 4:
            continue
        freeze = after[0]["t"] - last["t"]
        tail, cur_tail = [after[0]], [after[0]]
        for a, b in zip(after, after[1:]):
            if b["t"] - a["t"] > 400:
                break
            cur_tail.append(b)
        tail = cur_tail
        tgaps = [b["t"] - a["t"] for a, b in zip(tail, tail[1:])]
        tails.append({
            "freeze": freeze,
            "n": len(tail),
            "dur": tail[-1]["t"] - tail[0]["t"],
            "cadence": st.median(tgaps) if tgaps else 0.0,
            "px": sum(abs(o["dy"]) for o in tail),
            "first_px": abs(tail[0]["dy"]),
            "subpixel": sum(1 for o in tail if abs(o["dy"] % 1.0) > 0.05),
        })
    if tails:
        fr = [t["freeze"] for t in tails]
        print(f"  放手次數={len(tails)}  凍結窗口 median={st.median(fr):.0f}ms  p95={sorted(fr)[int(len(fr)*.95)]:.0f}ms  max={max(fr):.0f}ms")
        print(f"  慣性段：事件 median={st.median(t['n'] for t in tails):.0f} 個  長度 median={st.median(t['dur'] for t in tails):.0f}ms  "
              f"節奏 median={st.median(t['cadence'] for t in tails):.1f}ms  總位移 median={st.median(t['px'] for t in tails):.0f}px")
        print(f"  慣性第一幀位移 median={st.median(t['first_px'] for t in tails):.2f}px（接近 0 表示第一幀白睡一次）  "
              f"帶小數的幀 {sum(t['subpixel'] for t in tails)}/{sum(t['n'] for t in tails)}")
    else:
        print("  （找不到放手點）")

    # 放手邊界：packet 尾巴速度對上慣性起始速度。倍率小於 1 就是放手瞬間被剎車，
    # 使用者報的「有时候抖动」多半就是這裡，而不是滑行本身。
    coast = [o for o in outputs if not any(abs(o["t"] - p["t"]) < 4 for p in inputs)]
    if coast:
        print("\n── 放手邊界銜接（packet 尾巴速度 vs 慣性起始速度）")
        ratios = []
        for i, p in enumerate(inputs):
            nxt = inputs[i + 1]["t"] if i + 1 < len(inputs) else p["t"] + 10 ** 9
            if nxt - p["t"] < 120:
                continue
            seg = inputs[max(0, i - 2):i + 1]
            dts = [seg[j + 1]["t"] - seg[j]["t"] for j in range(len(seg) - 1)]
            if len(dts) < 2:
                continue
            pre = sum(abs(e["dy"]) for e in seg[:-1]) / sum(dts) * 1000.0
            tail = [c for c in coast if p["t"] < c["t"] < p["t"] + 1500]
            if len(tail) < 3:
                continue
            post = sum(abs(tail[j]["dy"]) / (tail[j]["t"] - tail[j - 1]["t"]) * 1000.0 for j in (1, 2)) / 2.0
            if pre < 30 or post < 20:
                continue
            ratios.append(post / pre)
        if ratios:
            print(f"  放手 {len(ratios)} 次：median={st.median(ratios):.2f}×  "
                  f"p10={sorted(ratios)[max(0, int(len(ratios) * .1))]:.2f}×  "
                  f"p90={sorted(ratios)[int(len(ratios) * .9)]:.2f}×")
            print(f"  急剎(<0.6×) {sum(1 for r in ratios if r < 0.6)}/{len(ratios)}   "
                  f"竄出去(>1.5×) {sum(1 for r in ratios if r > 1.5)}/{len(ratios)}   "
                  f"{GOOD if st.median(ratios) > 0.8 else WARN} 理想是接近 1.00×（放手後維持原速滑行）")
        else:
            print("  （找不到可做邊界比較的快速放手）")
        runs, cur = [], [coast[0]]
        for a, b in zip(coast, coast[1:]):
            if b["t"] - a["t"] > 120:
                if len(cur) > 3:
                    runs.append(cur)
                cur = [b]
            else:
                cur.append(b)
        if len(cur) > 3:
            runs.append(cur)
        bumps = frames = 0
        for r in runs:
            vs = [abs(r[j]["dy"]) / (r[j]["t"] - r[j - 1]["t"]) * 1000.0 for j in range(1, len(r))]
            frames += len(vs)
            bumps += sum(1 for a, b in zip(vs, vs[1:]) if a > 30 and b / a > 1.25)
        print(f"  滑行中途速度回升 >25%：{bumps}/{frames} 个样本（{100 * bumps / max(1, frames):.1f}%）")

    print("\n── 离线模拟（只喂 client packet 序列，不含 Lumen 现有惯性）")
    run_compare(inputs)
    return 0


if __name__ == "__main__":
    sys.exit(main())
