"""results/ の計測結果を、Markdown形式にまとめる"""

import csv
from collections import defaultdict
from pathlib import Path

RESULTS = Path(__file__).resolve().parent.parent / "results"

# ID, 表に出す構成名, 待ち方
ROWS = [
    ("py-async-wait", "Python シングルプロセス × シングルスレッド", "非同期で待つ"),
    ("py-async-block", "Python シングルプロセス × シングルスレッド", "同期で待つ"),
    ("py-sync-block", "Python シングルプロセス × マルチスレッド", "同期で待つ"),
    ("py-mp-async-block", "Python マルチプロセス × シングルスレッド", "同期で待つ"),
    ("py-mp-sync-block", "Python マルチプロセス × マルチスレッド", "同期で待つ"),
    ("go-sleep", "Go（GOMAXPROCS=1）", "同期で待つ"),
    ("py-cpu-async", "Python CPU 処理（`async def`）", "CPU 処理"),
    ("py-cpu-sync", "Python CPU 処理（`def`）", "CPU 処理"),
    ("go-cpu", "Go CPU 処理（GOMAXPROCS=1）", "CPU 処理"),
]


def seconds(ms: str) -> str:
    v = float(ms) / 1000
    return f"{v:.3f}秒" if v < 1 else f"{v:.1f}秒"


def threads(run_id: str) -> str:
    """負荷中に観測した、プロセスごとの最大 OS スレッド数"""
    path = RESULTS / f"{run_id}.threads"
    if not path.exists():
        return "-"
    peak: dict[str, int] = defaultdict(int)
    for line in path.read_text().splitlines():
        parts = line.split(None, 2)
        if len(parts) >= 2 and parts[1].isdigit():
            peak[parts[0]] = max(peak[parts[0]], int(parts[1]))
    if len(peak) > 1:
        peak.pop("1", None)  # gunicorn のマスタープロセスは数えない
    if not peak:
        return "-"
    top = max(peak.values())
    return f"{top} × {len(peak)}プロセス" if len(peak) > 1 else str(top)


def main() -> None:
    print("| 構成 | 待ち方 | 負荷中の OS スレッド数 | RPS | 対象の応答時間（中央値） | `/ping` の応答時間（中央値） | 失敗数 |")
    print("|---|---|---|---|---|---|---|")
    for run_id, label, kind in ROWS:
        path = RESULTS / f"{run_id}_stats.csv"
        if not path.exists():
            continue
        stats = {row["Name"]: row for row in csv.DictReader(path.open())}
        total = stats["Aggregated"]
        target = next(r for n, r in stats.items() if n not in ("Aggregated", "/ping"))
        ping = stats.get("/ping")
        print(
            f"| {label} | {kind} | {threads(run_id)} "
            f"| {float(total['Requests/s']):.1f} "
            f"| {seconds(target['Median Response Time'])} "
            f"| {seconds(ping['Median Response Time']) if ping else '-'} "
            f"| {total['Failure Count']} |"
        )


if __name__ == "__main__":
    main()
