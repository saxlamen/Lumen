#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
lumen-scroll-census.py — 把 Lumen log 裡的 "Scroll census" 行抽出來排成表格。

census 是 src/input.cpp 裡的計數（要 macos_smooth_scrolling_diagnostics = enabled）：
  client packets   = 從 Moonlight 收到的 scroll packet 數（batch 之前）
  injected events  = 實際交給平台的 scroll 事件數（batch 之後）
  avg_gap          = 各自的平均間隔（ms）
  packets_per_event= 平均幾個 packet 被合成一個事件（=1 代表沒合併）

用法：
  python3 lumen-scroll-census.py                 # 最近 200 行
  python3 lumen-scroll-census.py --since "10:31" # 只看在 10:31 之後
  python3 lumen-scroll-census.py --csv out.csv   # 匯出（要跟 scroll-data 的 CSV 對時用）
  python3 lumen-scroll-census.py --all           # 全部（含 rotate 掉的 log）
"""

import argparse
import datetime as dt
import glob
import os
import re
import sys

LOG_PATH = os.path.expanduser("~/.config/sunshine/sunshine.log")
LINE_RE = re.compile(
    r"\[(?P<date>[\d-]+) (?P<time>[\d:.]+)\].*Scroll census \[(?P<window>[\d.]+)s\]: "
    r"client packets=(?P<packets>\d+) avg_gap=(?P<recv_gap>[\d.]+)ms max_gap=(?P<recv_max>[\d.]+)ms"
    r" \| injected events=(?P<injected>\d+) avg_gap=(?P<inj_gap>[\d.]+)ms max_gap=(?P<inj_max>[\d.]+)ms"
    r" \| packets_per_event=(?P<ppe>[\d.]+) merged_away=(?P<merged>\d+)"
)


def parse(paths):
    rows = []
    for path in sorted(paths):
        if not os.path.exists(path):
            continue
        with open(path, encoding="utf-8", errors="replace") as fh:
            for line in fh:
                match = LINE_RE.search(line)
                if not match:
                    continue
                row = match.groupdict()
                row["stamp"] = dt.datetime.strptime(row["date"] + " " + row["time"][:8], "%Y-%m-%d %H:%M:%S")
                for key in ("window", "packets", "injected", "merged"):
                    row[key] = float(row[key])
                for key in ("recv_gap", "recv_max", "inj_gap", "inj_max", "ppe"):
                    row[key] = float(row[key])
                rows.append(row)
    rows.sort(key=lambda r: r["stamp"])
    return rows


def main():
    ap = argparse.ArgumentParser(description="Lumen Scroll census 檢視器")
    ap.add_argument("--log", default=LOG_PATH)
    ap.add_argument("--all", action="store_true", help="含 rotate 出去的 sunshine.log.N")
    ap.add_argument("--since", help="只看這個時刻之後，例如 10:31 或 10:31:20")
    ap.add_argument("--tail", type=int, default=200, help="只列最後 N 筆（預設 200）")
    ap.add_argument("--csv", help="額外匯出 CSV")
    args = ap.parse_args()

    paths = [args.log]
    if args.all:
        paths += sorted(glob.glob(args.log + ".*"), key=lambda p: -os.path.getmtime(p))
    rows = parse(paths)

    if args.since:
        needle = args.since if len(args.since) > 5 else args.since + ":00"
        cutoff = dt.datetime.strptime(needle[-8:], "%H:%M:%S").time()
        rows = [r for r in rows if r["stamp"].time() >= cutoff]

    if not rows:
        print(f"{args.log} 裡還沒有 'Scroll census' 行。")
        print("確認 ~/.config/sunshine/sunshine.conf 有 macos_smooth_scrolling_diagnostics = enabled，")
        print("然後從 client 滑幾秒（census 只在有滾動時才會輸出）。")
        return 1

    shown = rows[-args.tail:]
    print(f"{'時刻':<10}{'packets':>9}{'平均間隔':>10}{'最大間隔':>10}{'注入事件':>10}{'平均間隔':>10}"
          f"{'最大間隔':>10}{'pkt/event':>11}{'被吞掉':>8}")
    for row in shown:
        print(f"{row['stamp'].strftime('%H:%M:%S'):<10}{row['packets']:>9.0f}{row['recv_gap']:>10.2f}"
              f"{row['recv_max']:>10.1f}{row['injected']:>10.0f}{row['inj_gap']:>10.2f}{row['inj_max']:>10.1f}"
              f"{row['ppe']:>11.2f}{row['merged']:>8.0f}")

    total_packets = sum(r["packets"] for r in rows)
    total_injected = sum(r["injected"] for r in rows)
    span = sum(r["window"] for r in rows) or 1.0
    print("-" * 78)
    print(f"合計 {len(rows)} 個統計窗（{span:.0f}s）：client packets={total_packets:.0f} "
          f"({total_packets/span:.1f}Hz)  injected events={total_injected:.0f} ({total_injected/span:.1f}Hz)  "
          f"packets_per_event={1 + sum(r['merged'] for r in rows) / max(1, total_injected):.2f}")
    print("判讀：packets_per_event≈1 且 injected 間隔≈client 間隔 → 主機沒合併，頓來自 client；")
    print("      packets_per_event>1 且 injected 間隔明顯大於 client 間隔 → 是 Sunshine 端 batch 合併。")

    if args.csv:
        with open(args.csv, "w", encoding="utf-8") as fh:
            fh.write("time,window_s,packets,recv_gap_ms,recv_max_ms,injected,inj_gap_ms,inj_max_ms,packets_per_event,merged\n")
            for row in rows:
                fh.write(f"{row['stamp'].isoformat()},{row['window']},{row['packets']:.0f},{row['recv_gap']},"
                         f"{row['recv_max']},{row['injected']:.0f},{row['inj_gap']},{row['inj_max']},{row['ppe']},{row['merged']:.0f}\n")
        print(f"已匯出 {args.csv}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
