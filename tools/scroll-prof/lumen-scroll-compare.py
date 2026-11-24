#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
lumen-scroll-compare.py — 比較原生 / Lumen / RustDesk 的 scroll 事件剖面。

讀 lumen-scroll-profile.command 記錄的 CSV，算出「順不順」的可量化指標：
事件節奏、 jitter、次像素位移、phase/momentum 有無、慣性尾韻長度與衰減常數、
尾韻被切斷時的跳變、每步速度變化（jerk）。

用法：
  python3 lumen-scroll-compare.py                    # 自動讀 var/scroll-data（桌面有軟鏈）/*.csv
  python3 lumen-scroll-compare.py a.csv b.csv        # 只比這幾個
  python3 lumen-scroll-compare.py --gestures a.csv   # 多列每個手勢的明細 + 速度曲線
  python3 lumen-scroll-compare.py --json a.csv       # 機器可讀輸出
"""

import argparse
import csv
import glob
import json
import math
import os
import statistics as st
import sys

SPARK = "▁▂▃▄▅▆▇█"

# Lumen 的常數（src/platform/macos/smooth_scroll.mm），拿來對照指紋用
LUMEN = {
    "RELEASE_THRESHOLD_MS": 25.0,   # 手停 -> 開始模擬慣性 的等待
    "FRAME_DURATION_MS": 8.0,       # 慣性迴圈 sleep
    "FRICTION_PER_SECOND": 5.5,     # exp(-5.5 * t)
    "MIN_VELOCITY": 12.0,           # 低於這個速度直接停
    "MAX_VELOCITY": 2800.0,
    "PIXELS_PER_TICK": 44.0,
}


# ---------------------------------------------------------------- 基本工具

def pct(values, q):
    if not values:
        return float("nan")
    values = sorted(values)
    if len(values) == 1:
        return values[0]
    pos = (len(values) - 1) * q
    lo = int(math.floor(pos))
    hi = min(lo + 1, len(values) - 1)
    return values[lo] + (values[hi] - values[lo]) * (pos - lo)


def fnum(value, digits=1):
    if value is None or (isinstance(value, float) and math.isnan(value)):
        return "-"
    return f"{value:.{digits}f}"


def sparkline(series, width=36):
    if not series:
        return ""
    step = max(1, len(series) // width)
    sampled = series[::step][:width]
    peak = max(abs(v) for v in sampled) or 1.0
    return "".join(SPARK[min(7, int(abs(v) / peak * 7.999))] for v in sampled)


# ---------------------------------------------------------------- 讀 CSV

class Run:
    def __init__(self, path, bin_ms=None):
        self.path = path
        self.meta = {}
        self.rows = []
        self._load()
        self.bin_ms = bin_ms or self._display_bin()
        self.notes = []
        self._pick_level()
        self._pick_axis()
        self._calibrate()
        self.gestures = self._segment()
        self.stats = self._summarize()

    def _load(self):
        header = None
        with open(self.path, encoding="utf-8") as fh:
            for line in fh:
                line = line.rstrip("\n")
                if line.startswith("#"):
                    body = line[1:].strip()
                    if "=" in body:
                        key, value = body.split("=", 1)
                        self.meta[key.strip()] = value
                    continue
                if not line.strip():
                    continue
                cells = next(csv.reader([line]))
                if header is None:
                    header = cells
                    continue
                row = {}
                for key, cell in zip(header, cells):
                    row[key] = _num(cell)
                self.rows.append(row)
        self.rows = [r for r in self.rows if isinstance(r.get("t_ms"), float)]

    def label(self):
        return self.meta.get("label") or os.path.basename(self.path).split("_")[0]

    def _display_bin(self):
        """用記錄到的更新率決定測速窗口（app 是以帧在渲染，不是以事件）。"""
        for value in self.meta.get("display", "").split("|"):
            if value.rstrip("Hz").rstrip("h").isdigit():
                hz = float(value.rstrip("Hz").rstrip("h"))
                if hz > 0:
                    return 1000.0 / hz
        return 1000.0 / 60.0

    def tag(self):
        name = self.label()
        stamp = self.meta.get("started", "")[5:16].replace("T", " ")
        return f"{name} {stamp}".strip()

    def _pick_level(self):
        levels = {}
        for row in self.rows:
            levels.setdefault(int(row["level"]), []).append(row)
        if not levels:
            self.level_rows, self.level, self.level_note = [], -1, "沒有事件"
            self.other_levels = "無"
            return
        # 同一個事件會同時出現在 HID 與 session 兩層；選收到最多事件的那層當主資料。
        self.level = max(levels, key=lambda k: len(levels[k]))
        self.level_rows = sorted(levels[self.level], key=lambda r: r["t_ms"])
        others = {k: len(v) for k, v in levels.items() if k != self.level}
        names = {0: "HID", 1: "session"}
        self.level_note = names.get(self.level, str(self.level))
        self.other_levels = ", ".join(f"{names.get(k, k)}={v}" for k, v in others.items()) or "無"

    def _pick_axis(self):
        if not self.level_rows:
            self.axis = "y"
            return
        y = sum(abs(r["point_y"] or 0) for r in self.level_rows)
        x = sum(abs(r["point_x"] or 0) for r in self.level_rows)
        self.axis = "y" if y >= x else "x"

    def px(self, row):
        return row["point_y"] if self.axis == "y" else row["point_x"]

    def _calibrate(self):
        """fixed_y/fixed_x 的單位不是寫死的：實測 Lumen 的事件是「line 的 16.16」，
        原生事件可能是「像素的 16.16」。用 fixed/point 的中位比值自己校準。"""
        ratios = []
        key_f = "fixed_y" if self.axis == "y" else "fixed_x"
        for row in self.level_rows:
            point = self.px(row) or 0
            fixed = row.get(key_f)
            if abs(point) >= 2 and isinstance(fixed, float) and abs(fixed) > 1e-9:
                ratio = fixed / point
                if 0.001 < abs(ratio) < 1000:
                    ratios.append(ratio)
        self.fixed_scale = st.median(ratios) if ratios else 1.0

    def px_val(self, row):
        """这个事件的位移（px），可能带次像素。"""
        point = self.px(row) or 0.0
        fixed = row.get("fixed_y" if self.axis == "y" else "fixed_x")
        if not isinstance(fixed, float) or not self.fixed_scale:
            return point
        fixed_px = fixed / self.fixed_scale
        if point == 0 or abs(abs(fixed_px) - abs(point)) <= max(1.0, abs(point) * 0.5):
            return fixed_px
        return point

    def _time_col(self):
        if getattr(self, "_time_col_name", None):
            return self._time_col_name
        col = "t_ms"
        note = "事件時間戳"
        times = [r["t_ms"] or 0 for r in self.level_rows]
        bad = sum(1 for a, b in zip(times, times[1:]) if b < a)
        unique = len({round(t, 3) for t in times})
        try:
            wall_s = float(self.meta.get("duration_s") or 0)
        except ValueError:
            wall_s = 0
        span = (times[-1] - times[0]) if times else 0
        if wall_s > 0 and span > 3 * wall_s * 1000:
            col = "recv_ms"
            note = f"事件時間戳異常（跨度是記錄長度的 {span / (wall_s * 1000):.1f} 倍），改用 tap 抵達時刻"
        elif bad > len(times) * 0.05 or unique < max(3, len(times) * 0.2):
            col = "recv_ms"
            note = "事件時間戳不可靠，改用 tap 抵達時刻"
        self._time_col_name, self.time_note = col, note
        return col

    # ------------------------------------------------------------ 手勢切分

    def _segment(self):
        if not self.level_rows:
            return []
        col = self._time_col()
        gestures, current = [], []
        prev = None
        for row in self.level_rows:
            if prev is not None:
                gap = (row[col] or 0) - (prev[col] or 0)
                # 只用空檔切手勢：phase ended 之後的 momentum 尾巴要算同一個手勢。
                if gap > 120:
                    if current:
                        gestures.append((col, current))
                    current = []
            current.append(row)
            prev = row
        if current:
            gestures.append((col, current))
        return [self._gesture(col, g) for col, g in gestures]

    def _gesture(self, col, rows):
        g = {"n": len(rows), "t0": rows[0][col], "t1": rows[-1][col]}
        g["dur_ms"] = g["t1"] - g["t0"]
        # CSV 裡的 point_y/point_x 是「這個事件自己帶的位移」（不是累計位置）。
        intervals, deltas = [], []
        g["dist_px"] = sum(abs(self.px_val(r)) for r in rows)
        for a, b in zip(rows, rows[1:]):
            intervals.append(max((b[col] or 0) - (a[col] or 0), 0.001))
            deltas.append(self.px_val(b) or 0)
        g["intervals"], g["deltas"] = intervals, deltas

        # 逐事件速度：兩個事件差 0.08 ms 這種暴增會讓速度出現幾萬 px/s 的假峰值。
        raw_v = [d / (dt / 1000.0) for d, dt in zip(deltas, intervals)]
        g["v_raw_max"] = max((abs(v) for v in raw_v), default=0.0)
        g["burst_pct"] = 100.0 * sum(1 for i in intervals if i < 4.0) / max(1, len(intervals))

        # 以顯示器帧切窗計速 = app 實際看到的畫面速度（也是人眼看到的）。
        series = self._frame_velocity(rows, col)
        g["velocities"] = [v for _, v in series]  # 保留欄位名稱給 sparkline 用
        g["frames"] = series
        if series:
            g["peak_v"] = max(abs(v) for _, v in series)
            g["i_peak"] = max(range(len(series)), key=lambda i: abs(series[i][1]))
        else:
            g["peak_v"], g["i_peak"] = 0.0, 0
        if len(series) >= 2:
            steps = [abs(b - a) for (_, a), (_, b) in zip(series, series[1:])]
            g["dv_p95"], g["dv_max"] = pct(steps, 0.95), max(steps)
        else:
            g["dv_p95"] = g["dv_max"] = 0.0
        g["zero_frame_pct"] = (100.0 * sum(1 for _, v in series if abs(v) < 0.05 * max(1.0, g["peak_v"]))
                               / len(series)) if series else 0.0

        tail = series[g["i_peak"]:] if series else []
        tail_intervals = []
        for (_, a), (_, b) in zip(tail, tail[1:]):
            tail_intervals.append(b - a)
        g["tail_n"] = len(tail)
        g["tail_dur_ms"] = (tail[-1][0] - tail[0][0]) if len(tail) >= 2 else 0.0
        # 收尾速度：最後 100 ms 的平均速度（單个帧会被 1 px 的解析度卡住）
        t_end = rows[-1][col] or 0
        last100 = [r for r in rows if (r[col] or 0) >= t_end - 100]
        g["tail_end_v"] = sum(abs(self.px_val(r)) for r in last100) / 0.1
        g["last_frame_px"] = abs(sum(self.px_val(r) for r in last100 if (r[col] or 0) >= t_end - self.bin_ms))
        g["tail_start_v"] = abs(tail[0][1]) if tail else 0.0
        g["friction"], g["friction_r2"] = _fit_decay([v for _, v in tail], tail_intervals)

        g["gap_max"] = max(intervals) if intervals else 0.0
        # 峰後的空檔：Lumen 的 RELEASE_THRESHOLD 會在這裡留指紋
        t_peak = series[g["i_peak"]][0] if series else g["t0"]
        after = [(b[col] or 0) - (a[col] or 0) for a, b in zip(rows, rows[1:]) if (a[col] or 0) >= t_peak]
        g["gap_max_tail"] = max(after) if after else 0.0
        key_f = "fixed_y" if self.axis == "y" else "fixed_x"
        subs = [r for r in rows if abs(self.px_val(r)) % 1.0 > 1e-6 or abs((r.get(key_f) or 0)) % self.fixed_scale > 1e-6]
        g["subpixel_frac"] = len(subs) / max(1, len(rows))
        g["cont_frac"] = sum(1 for r in rows if int(r.get("continuous") or 0) == 1) / max(1, len(rows))
        g["phase_frac"] = sum(1 for r in rows if int(r.get("phase") or 0) in (1, 2, 4, 8)) / max(1, len(rows))
        g["momentum_frac"] = sum(1 for r in rows if int(r.get("momentum") or 0) in (1, 2, 3)) / max(1, len(rows))
        g["cv"] = (st.pstdev(intervals) / st.mean(intervals)) if len(intervals) > 1 and st.mean(intervals) > 0 else 0.0
        g["median_interval"] = pct(intervals, 0.5)
        # 手指階段 vs 尾韻階段的節奏分開看：注入型軟體這兩段常常是不一樣的頻率。
        half = max(2, len(rows) // 2)
        first_half, second_half = intervals[:max(0, half - 1)], intervals[half - 1:]
        g["hand_median"] = pct(first_half, 0.5) if len(first_half) >= 2 else g["median_interval"]
        g["tail_median"] = pct(second_half, 0.5) if len(second_half) >= 2 else g["median_interval"]
        return g

    def _frame_velocity(self, rows, col):
        """把每事件的位移累進 1/bin_ms 的窗口 → 每帧的 px/s（窗口內沒事件就是 0）。"""
        if not rows:
            return []
        width = self.bin_ms
        t0, t1 = rows[0][col], rows[-1][col]
        count = int((t1 - t0) // width) + 1
        acc = [0.0] * count
        for row in rows:
            index = int(((row[col] or 0) - t0) // width)
            index = min(max(index, 0), count - 1)
            acc[index] += self.px_val(row) or 0.0
        return [(t0 + (i + 0.5) * width, acc[i] / (width / 1000.0)) for i in range(count)]

    # ------------------------------------------------------------ run 層級統計

    def _summarize(self):
        s = {"n_events": len(self.level_rows), "n_gestures": len(self.gestures)}
        if not self.level_rows:
            return s
        rows = self.level_rows
        col = self._time_col()
        s["duration_ms"] = (rows[-1][col] or 0) - (rows[0][col] or 0)
        intervals = [g for gg in self.gestures for g in gg["intervals"]]
        s["rate_hz"] = (len(rows) - 1) / (s["duration_ms"] / 1000.0) if s["duration_ms"] > 1 else 0.0
        s["rate_in_gesture_hz"] = 1000.0 / pct(intervals, 0.5) if intervals else 0.0

        s["int_med"], s["int_p95"], s["int_max"] = pct(intervals, 0.5), pct(intervals, 0.95), (max(intervals) if intervals else 0)
        s["int_cv"] = st.mean([gg["cv"] for gg in self.gestures if len(gg["intervals"]) > 1]) if intervals else 0.0
        hands = [gg["hand_median"] for gg in self.gestures if gg["i_peak"] >= 2]
        tails = [gg["tail_median"] for gg in self.gestures if len(gg["intervals"]) - gg["i_peak"] >= 2]
        s["hand_interval_med"] = st.mean(hands) if hands else float("nan")
        s["tail_interval_med"] = st.mean(tails) if tails else float("nan")
        n = max(1, len(intervals))
        s["int_gt16"] = 100.0 * sum(1 for i in intervals if i > 16.7) / n
        s["int_gt25"] = 100.0 * sum(1 for i in intervals if i > 25.0) / n
        s["int_gt33"] = 100.0 * sum(1 for i in intervals if i > 33.0) / n

        s["hist"] = _histogram(intervals)
        deltas = [abs(d) for gg in self.gestures for d in gg["deltas"]]
        s["d_med"], s["d_p95"] = pct(deltas, 0.5), pct(deltas, 0.95)
        s["zero_delta_pct"] = 100.0 * sum(1 for d in deltas if d == 0) / max(1, len(deltas))
        s["subpixel_pct"] = 100.0 * st.mean([gg["subpixel_frac"] for gg in self.gestures])
        s["cont_pct"] = 100.0 * st.mean([gg["cont_frac"] for gg in self.gestures])
        s["phase_pct"] = 100.0 * st.mean([gg["phase_frac"] for gg in self.gestures])
        s["momentum_pct"] = 100.0 * st.mean([gg["momentum_frac"] for gg in self.gestures])

        big = [gg for gg in self.gestures if gg["n"] >= 4]
        s["peak_v_med"] = st.mean([gg["peak_v"] for gg in big]) if big else 0.0
        s["peak_v_max"] = max([gg["peak_v"] for gg in big], default=0.0)
        s["dist_med"] = st.mean([gg["dist_px"] for gg in big]) if big else 0.0
        s["tail_dur_med"] = st.mean([gg["tail_dur_ms"] for gg in big if gg["tail_n"] >= 3]) if big else 0.0
        s["tail_end_v_med"] = st.mean([gg["tail_end_v"] for gg in big if gg["tail_n"] >= 3]) if big else 0.0
        s["last_frame_px_med"] = st.mean([gg["last_frame_px"] for gg in big if gg["tail_n"] >= 3]) if big else 0.0
        frictions = [gg["friction"] for gg in big if gg.get("friction") is not None and gg["friction_r2"] > 0.6]
        s["friction_med"] = st.mean(frictions) if frictions else None
        s["dv_p95_med"] = st.mean([gg["dv_p95"] for gg in big if len(gg["velocities"]) >= 2]) if big else 0.0
        s["zero_frame_pct"] = st.mean([gg["zero_frame_pct"] for gg in big if len(gg["velocities"]) >= 3]) if big else 0.0
        s["burst_pct"] = st.mean([gg["burst_pct"] for gg in self.gestures]) if self.gestures else 0.0
        s["v_raw_max"] = max([gg["v_raw_max"] for gg in self.gestures], default=0.0)
        s["frame_jump_max"] = max([gg["peak_v"] * self.bin_ms / 1000.0 for gg in self.gestures], default=0.0)
        s["frame_jump_med"] = st.mean([gg["peak_v"] * self.bin_ms / 1000.0 for gg in big]) if big else 0.0
        s["bin_ms"] = self.bin_ms
        s["gap_tail_med"] = st.mean([gg["gap_max_tail"] for gg in big]) if big else 0.0
        s["lag_us_med"] = pct([r["lag_us"] for r in rows if isinstance(r.get("lag_us"), float)], 0.5)

        s["src_pids"] = {}
        for row in rows:
            pid = int(row.get("src_pid") or 0)
            s["src_pids"][pid] = s["src_pids"].get(pid, 0) + 1
        s["fixed_scale"] = self.fixed_scale
        try:
            wall_ms = float(self.meta.get("duration_s") or 0) * 1000
            s["ts_sanity"] = ((rows[-1]["t_ms"] or 0) - (rows[0]["t_ms"] or 0)) / wall_ms if wall_ms > 0 else None
        except ValueError:
            s["ts_sanity"] = None

        cadence = 100.0 * math.exp(-((s["int_cv"] or 0) / 0.25) ** 2)
        steady = 100.0 * math.exp(-(s["dv_p95_med"] / 400.0) ** 2)
        tail = (100.0 * min(1.0, s["tail_dur_med"] / 500.0)) * math.exp(-((s["tail_end_v_med"] / 150.0) ** 2))
        s["score"] = 0.4 * cadence + 0.3 * steady + 0.3 * tail
        s["score_parts"] = (cadence, steady, tail)
        return s

    # ------------------------------------------------------------ 自動註解

    def flag_issues(self):
        s, notes = self.stats, []
        if s.get("n_events", 0) < 5:
            notes.append("事件太少：這次記錄基本無效（權限？沒人滑？SSH？）")
            return notes
        if s.get("ts_sanity") and s["ts_sanity"] > 3:
            notes.append(f"CSV 的 t_ms 是實際時間的 {s['ts_sanity']:.1f} 倍（時間戳單位問題），"
                         "已自動改用 tap 抵達時刻算節奏")
        if self.label() == "native" and s["src_pids"] and max(s["src_pids"], key=s["src_pids"].get) != 0:
            pid = max(s["src_pids"], key=s["src_pids"].get)
            notes.append(f"label 是 native，但事件主要來自 pid {pid}"
                         f"（{getattr(self, 'meta_src_names', {}).get(pid, '?')}）→ 这不是真裝置，是某個程式注入的")
        if s["phase_pct"] < 5:
            notes.append("事件都沒有 scroll phase → 對 macOS 來說是「無階段」的合成事件，"
                         "app 端用不到 began/changed/ended 的處理路徑")
        if s["momentum_pct"] < 5:
            notes.append("沒有 momentum phase（begin/continue/end）→ 系統不會幫忙接慣性，尾韻完全靠注入端自己模拟")
        if s["subpixel_pct"] < 5:
            notes.append("只有整數像素位移、沒有次像素 → 慢速滑動會有顆粒感（原生 trackpad 有 16.16 次像素）")
        if s["cont_pct"] < 50:
            notes.append("continuous 旗標多半是 0 → 會被當成傳統滾輪，逐格跳")
        if s["rate_in_gesture_hz"] and s["rate_in_gesture_hz"] < 90:
            notes.append(f"手勢內事件率只有 {s['rate_in_gesture_hz']:.0f} Hz（原生 trackpad 大約 110–130 Hz）："
                         "畫面只能以這個頻率收到新位置")
        if s["tail_interval_med"] == s["tail_interval_med"] and s["hand_interval_med"] == s["hand_interval_med"] \
                and s["tail_interval_med"] > 0 and abs(s["hand_interval_med"] - s["tail_interval_med"]) > 3.0:
            notes.append(f"前半段 {s['hand_interval_med']:.1f} ms、後半段 {s['tail_interval_med']:.1f} ms："
                         "同一個手勢內節奏不一致（兩個不一樣的來源/迴圈）")
        if s["burst_pct"] > 3:
            notes.append(f"{s['burst_pct']:.0f}% 的事件相隔 < 4 ms（封包暴增）：逐事件看會看到假的速度峰值，"
                         "表裡的速度已改成按显示帧切窗")
        if s["frame_jump_med"] > 40:
            notes.append(f"app 每一帧收到的位移中位就有 {s['frame_jump_med']:.0f} px"
                         f"（峰 {s['frame_jump_max']:.0f} px/帧）：位移是「大块大块」送进来的，"
                         "不是每帧均匀推进")
        if s["zero_frame_pct"] > 6:
            notes.append(f"手勢中有 {s['zero_frame_pct']:.0f}% 的帧完全沒有新位移"
                         f"（以 {s['bin_ms']:.1f} ms/帧算）→ 視覺上就是一頓一頓")
        if 18 <= s["gap_tail_med"] <= 32:
            notes.append(f"手勢峰後最大空檔中位數 {s['gap_tail_med']:.0f} ms，"
                         f"跟 Lumen RELEASE_THRESHOLD={LUMEN['RELEASE_THRESHOLD_MS']:.0f}ms 吻合")
        buckets = s["hist"]
        b8 = sum(buckets[k] for k in ("4-8", "8-12"))
        if b8 > 45 and s["phase_pct"] < 5:
            notes.append(f"{b8:.0f}% 的事件間隔落在 4–12 ms：定時注入的節奏"
                         f"（Lumen FRAME_DURATION={LUMEN['FRAME_DURATION_MS']:.0f}ms sleep）")
        if s["tail_end_v_med"] > 60:
            notes.append(f"尾韻最後一跳：{s['tail_end_v_med']:.0f} px/s 直接歸零（明顯「切掉」而非減到 0）")
        elif s["tail_end_v_med"] < 25:
            notes.append(f"尾韻收尾速度 {s['tail_end_v_med']:.0f} px/s，接近自然停下")
        if s["friction_med"] is not None:
            diff = abs(abs(s["friction_med"]) - LUMEN["FRICTION_PER_SECOND"])
            notes.append(f"尾韻衰減常數 {abs(s['friction_med']):.2f}/s"
                         + (f"（≈ Lumen FRICTION_PER_SECOND={LUMEN['FRICTION_PER_SECOND']}）" if diff < 1.2 else ""))
        if s["int_gt33"] > 8:
            notes.append(f"{s['int_gt33']:.0f}% 的間隔 > 33 ms：以 60Hz 顯示器來說等于每 2 帧以上才有進展")
        return notes


def _num(text):
    try:
        value = float(text)
        return int(value) if value.is_integer() and "." not in (text or "") else value
    except (TypeError, ValueError):
        return None


def _fit_decay(velocities, intervals):
    """對尾韻做 ln|v| ~ 直線，回傳斜率（衰減常數 1/s）與 R²。"""
    pts = []
    t = 0.0
    for i, v in enumerate(velocities):
        av = abs(v)
        if av > 1.0:
            pts.append((t, math.log(av)))
        if i < len(intervals):
            t += intervals[i] / 1000.0
    if len(pts) < 4:
        return None, 0.0
    xs = [p[0] for p in pts]
    ys = [p[1] for p in pts]
    mx, my = st.mean(xs), st.mean(ys)
    sxx = sum((x - mx) ** 2 for x in xs)
    if sxx <= 0:
        return None, 0.0
    sxy = sum((x - mx) * (y - my) for x, y in zip(xs, ys))
    slope = sxy / sxx
    intercept = my - slope * mx
    syy = sum((y - my) ** 2 for y in ys)
    ssr = sum((y - (slope * x + intercept)) ** 2 for x, y in zip(xs, ys))
    r2 = 1 - ssr / syy if syy > 0 else 0.0
    return slope, max(0.0, r2)


def _histogram(intervals):
    edges = [(0, 4), (4, 8), (8, 12), (12, 16), (16, 20), (20, 25), (25, 33), (33, 50), (50, 1e9)]
    names = ["0-4", "4-8", "8-12", "12-16", "16-20", "20-25", "25-33", "33-50", "50+"]
    out = {name: 0.0 for name in names}
    if not intervals:
        return out
    counts = {name: 0 for name in names}
    for value in intervals:
        for (lo, hi), name in zip(edges, names):
            if lo <= value < hi:
                counts[name] += 1
                break
    total = max(1, sum(counts.values()))
    for name in names:
        out[name] = 100.0 * counts[name] / total
    return out


# ---------------------------------------------------------------- 輸出

METRICS = [
    ("事件數", "n_events", "{:.0f}"),
    ("手勢數", "n_gestures", "{:.0f}"),
    ("記錄長度 ms", "duration_ms", "{:.0f}"),
    ("事件率 Hz（含空檔）", "rate_hz", "{:.1f}"),
    ("事件率 Hz（手勢內）", "rate_in_gesture_hz", "{:.1f}"),
    ("間隔 median ms", "int_med", "{:.2f}"),
    ("前半段間隔 ms", "hand_interval_med", "{:.2f}"),
    ("後半段間隔 ms", "tail_interval_med", "{:.2f}"),
    ("間隔 p95 ms", "int_p95", "{:.2f}"),
    ("間隔 max ms", "int_max", "{:.1f}"),
    ("間隔 CV(抖動)", "int_cv", "{:.3f}"),
    (">16.7ms %", "int_gt16", "{:.0f}"),
    (">25ms %", "int_gt25", "{:.0f}"),
    (">33ms %", "int_gt33", "{:.0f}"),
    ("每事件位移 med px", "d_med", "{:.2f}"),
    ("每事件位移 p95 px", "d_p95", "{:.1f}"),
    ("0 位移 %", "zero_delta_pct", "{:.0f}"),
    ("次像素位移 %", "subpixel_pct", "{:.0f}"),
    ("fixed/point 單位比", "fixed_scale", "{:.3f}"),
    ("t_ms/實際長度倍", "ts_sanity", "{:.2f}"),
    ("continuous %", "cont_pct", "{:.0f}"),
    ("phase %", "phase_pct", "{:.0f}"),
    ("momentum %", "momentum_pct", "{:.0f}"),
    ("峰值速度 med px/s", "peak_v_med", "{:.0f}"),
    ("峰值速度 max px/s", "peak_v_max", "{:.0f}"),
    ("單帧最大跳動 px", "frame_jump_max", "{:.0f}"),
    ("單帧跳動 med px", "frame_jump_med", "{:.1f}"),
    ("静止帧 %", "zero_frame_pct", "{:.1f}"),
    ("事件暴增 <4ms %", "burst_pct", "{:.1f}"),
    ("逐事件假峰值 px/s", "v_raw_max", "{:.0f}"),
    ("測速窗口 ms", "bin_ms", "{:.2f}"),
    ("單手勢距離 med px", "dist_med", "{:.0f}"),
    ("尾韻長度 med ms", "tail_dur_med", "{:.0f}"),
    ("尾韻收尾 px/s", "tail_end_v_med", "{:.0f}"),
    ("最後一帧位移 px", "last_frame_px_med", "{:.2f}"),
    ("尾韻衰減 1/s", "friction_med", "{:.2f}"),
    ("每步 Δv p95 px/s", "dv_p95_med", "{:.0f}"),
    ("峰後最大空檔 ms", "gap_tail_med", "{:.1f}"),
    ("tap 延遲 median us", "lag_us_med", "{:.0f}"),
    ("順暢度 0-100", "score", "{:.1f}"),
]


def print_compare(runs):
    names = [r.tag() for r in runs]
    width = max(26, max(len(n) for n in names) + 2)
    print("=" * (30 + width * len(runs)))
    print(f"{'指標':<28}" + "".join(f"{n:>{width}}" for n in names))
    print("-" * (30 + width * len(runs)))
    for title, key, spec in METRICS:
        cells = []
        for run in runs:
            value = run.stats.get(key)
            cells.append(("-" if value is None else spec.format(value)).rjust(width))
        print(f"{title:<28}" + "".join(cells))
    print("=" * (30 + width * len(runs)))
    print(f"{'事件層級(主)':<28}" + "".join(f"{r.level_note:>{width}}" for r in runs))
    print(f"{'主軸':<28}" + "".join(f"{r.axis:>{width}}" for r in runs))
    print()


def print_histogram(runs):
    names = [r.tag() for r in runs]
    keys = ["0-4", "4-8", "8-12", "12-16", "16-20", "20-25", "25-33", "33-50", "50+"]
    print("事件間隔分佈（% 的事件落在該 ms 區間；看節奏是自然連續還是定時注入）")
    width = 8
    print(f"{'':<10}" + "".join(f"{k:>{width}}" for k in keys) + "     ← 各 run")
    for run in runs:
        cells = "".join(f"{run.stats['hist'][k]:>{width}.1f}" for k in keys)
        print(f"{run.tag():<10}" + cells)
    print()


def print_gestures(run, limit=14):
    if not run.gestures:
        return
    print(f"\n── {run.tag()} 手勢明細（{run.axis} 軸，時間基準：{getattr(run, 'time_note', 't_ms')}）")
    print(f"{'#':>3} {'n':>4} {'長(ms)':>8} {'距離px':>8} {'峰px/s':>8} {'前半ms':>8} {'後半ms':>8} "
          f"{'尾韻長ms':>9} {'收尾px/s':>9} {'衰減':>6} {'Δv p95':>8} {'静帧%':>6} {'單帧最大px':>11}  速度曲線")
    for i, g in enumerate(run.gestures, 1):
        if i > limit:
            print(f"    … 還有 {len(run.gestures) - limit} 個")
            break
        frame_px = max((abs(v) * run.bin_ms / 1000.0 for _, v in g["frames"]), default=0.0)
        print(f"{i:>3} {g['n']:>4} {g['dur_ms']:>8.0f} {g['dist_px']:>8.0f} {g['peak_v']:>8.0f} "
              f"{g['hand_median']:>8.2f} {g['tail_median']:>8.2f} {g['tail_dur_ms']:>9.0f} {g['tail_end_v']:>9.0f} "
              f"{fnum(abs(g['friction']) if g['friction'] is not None else None, 2):>6} "
              f"{g['dv_p95']:>8.0f} {g['zero_frame_pct']:>6.1f} {frame_px:>11.0f}  {sparkline(g['velocities'])}")
    print()


def print_run_detail(run):
    stats = run.stats
    print(f"\n### {run.tag()}  ←  {os.path.basename(run.path)}")
    meta_bits = []
    for key in ("front_app", "display", "taps", "duration_s"):
        if key in run.meta:
            meta_bits.append(f"{key}={run.meta[key]}")
    print("    " + "  ".join(meta_bits))
    if getattr(run, "level_note", None):
        other = getattr(run, "other_levels", "")
        print(f"    事件層級：{run.level_note}（另一層：{other}）；時間基準：{getattr(run, 'time_note', 't_ms')}")
    pids = ", ".join(
        f"pid {pid} = {run.meta_src_names.get(pid, '?')} ({n} 個)"
        for pid, n in sorted(stats.get("src_pids", {}).items(), key=lambda kv: -kv[1])
    ) if hasattr(run, "meta_src_names") else ""
    if pids:
        print(f"    來源：{pids}")
    notes = run.flag_issues()
    if notes:
        print("    觀察：")
        for note in notes:
            print(f"      • {note}")


def main():
    ap = argparse.ArgumentParser(description="比較 scroll 事件剖面")
    ap.add_argument("files", nargs="*", help="CSV 檔（預設讀 var/scrollll-data/*.csv）")
    ap.add_argument("--gestures", action="store_true", help="列出每個手勢明細")
    ap.add_argument("--bin-ms", type=float, default=None, help="測速窗口 ms（預設用記錄到的更新率）")
    ap.add_argument("--json", action="store_true", help="輸出 JSON")
    args = ap.parse_args()

    files = args.files or sorted(glob.glob(os.path.expanduser("~/Scripts/Lumen/var/scrollop/scroll-data/*.csv")),
                                 key=os.path.getmtime)
    if not files:
        print("找不到 CSV。先跑 tools/scroll-prof/lumen-scroll-profile.command 記錄。")
        return 1

    runs = []
    for path in files:
        run = Run(path, bin_ms=args.bin_ms)
        names = {}
        for line in open(path, encoding="utf-8"):
            if not line.startswith("#"):
                break
            body = line[1:].strip()
            if body.startswith("src_pid="):
                pid_part, _, name = body[8:].partition("|")
                try:
                    names[int(pid_part)] = name
                except ValueError:
                    pass
        run.meta_src_names = names
        runs.append(run)

    if args.json:
        print(json.dumps([{"label": r.label(), "meta": r.meta, "stats": {k: v for k, v in r.stats.items()
                                                                         if k != "hist"},
                           "hist": r.stats.get("hist"),
                           "gestures": [{k: v for k, v in g.items()
                                         if k not in ("intervals", "deltas", "velocities")}
                                        for g in r.gestures],
                           "notes": r.flag_issues()}
                          for r in runs], ensure_ascii=False, indent=2, default=str))
        return 0

    print(f"\n讀 {len(runs)} 份記錄：")
    for run in runs:
        print(f"  · {run.tag():<18} {os.path.basename(run.path)}  events={run.stats.get('n_events', 0)}")
    print()
    if len(runs) > 1:
        print_compare(runs)
        print_histogram(runs)
    for run in runs:
        print_run_detail(run)
        if args.gestures or len(runs) == 1:
            print_gestures(run)
    if len(runs) > 1:
        best = max(runs, key=lambda r: r.stats.get("score", 0))
        worst = min(runs, key=lambda r: r.stats.get("score", 0))
        print(f"\n依「順暢度」排序：" + "  >  ".join(
            f"{r.tag()}({r.stats.get('score', 0):.0f})"
            for r in sorted(runs, key=lambda r: -r.stats.get("score", 0))))
        print(f"  最好：{best.tag()}   最差：{worst.tag()}")
        print("  （分數只是同一把尺的相對比較：節奏 40% + 速度穩定 30% + 尾韻 30%，見檔案尾註解）")
    print("\n註解：衰減常數越接近原生越好；Lumen 的 FRICTION_PER_SECOND=5.5、MIN_VELOCITY=12 px/s、"
          "RELEASE_THRESHOLD=25ms、FRAME_DURATION=8ms。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
