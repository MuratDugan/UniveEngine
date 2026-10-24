"""Median tables from bench/run.sh's results.tsv.   usage: python3 -I summarize.py results.tsv"""
import csv
import statistics
import sys
from collections import defaultdict

rows = list(csv.DictReader(open(sys.argv[1]), delimiter="\t"))
vals = defaultdict(list)
units = {}
for r in rows:
    try:
        v = float(r["value"])
    except ValueError:
        continue
    vals[(r["test"], r["backend"], r["metric"])].append(v)
    units[r["metric"]] = r["unit"]


def med(test, backend, metric):
    v = vals.get((test, backend, metric))
    return statistics.median(v) if v else None


def fmt(x, digits=1):
    return "-" if x is None else f"{x:.{digits}f}"


def count(test, backend, metric):
    return len(vals.get((test, backend, metric), []))


HIGHER_IS_BETTER = {"memcpy", "seq_write", "seq_read", "fps"}


def table(test, metrics, columns):
    present = [c for c in columns if any(count(test, c, m) for m in metrics)]
    if not present:
        return
    base = present[0]
    print(f"### {test} (median of {max(count(test, c, metrics[0]) for c in present)} runs)")
    head = ["metric", "unit"] + present + [f"{c} vs {base}" for c in present[1:]]
    print("| " + " | ".join(head) + " |")
    print("|" + "---|" * len(head))
    for m in metrics:
        cells = [m, units.get(m, "")] + [fmt(med(test, c, m), 2) for c in present]
        for c in present[1:]:
            a, b = med(test, base, m), med(test, c, m)
            if a and b:
                ratio = (b / a) if m in HIGHER_IS_BETTER else (a / b)
                cells.append(f"{ratio * 100:.0f}%")
            else:
                cells.append("-")
        print("| " + " | ".join(cells) + " |")
    print("(percent = speed relative to the first column; 100% = same speed)\n")


table("cpu", ["int", "float", "memcpy", "alloc", "thread_spawn", "int_all_cores", "clock_call"],
      ["native-arm64", "native-x86_64", "wine"])
table("files", ["seq_write", "seq_read", "small_create", "dir_list", "small_read", "small_delete"],
      ["native-arm64", "wine"])

gfx = sorted({(t, b) for (t, b, _m) in vals if t in ("d3d11", "d3d9")})
if gfx:
    print("### graphics (median)")
    cols = ["present_fps", "present_frame_p50", "present_frame_p99", "offscreen_fps", "offscreen_frame_p50",
            "offscreen_frame_p99", "device_create", "first_frame", "peekmessage"]
    print("| test | backend | " + " | ".join(cols) + " | dxvk banner | exit codes |")
    print("|" + "---|" * (len(cols) + 4))
    for t, b in gfx:
        exits = ",".join(str(int(x)) for x in vals.get((t, b, "exit"), []))
        banner = ",".join(str(int(x)) for x in vals.get((t, b, "dxvk_banner"), []))
        print(f"| {t} | {b} | " + " | ".join(fmt(med(t, b, c)) for c in cols) + f" | {banner} | {exits} |")
    print("(fps higher is better; frame times and start-up in ms; peekmessage in us/call)")
