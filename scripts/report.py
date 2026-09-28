"""results/ の計測結果からMarkdownを作る

    python3 scripts/report.py            # 画面に出す
    python3 scripts/report.py > results/report.md

構成ごとに、負荷の推移（10秒おき）、スレッド数の推移、結果を出し、最後に全構成の表を付ける。
"""

import csv
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from summarize import RESULTS, main as print_table  # noqa: E402

# ID: (サーバ, 起動方法, 対象のエンドポイント, 最大ユーザー数)
SCENARIOS = {
    "py-async-wait": ("Python", "uvicorn 1ワーカー", "/async-wait", 300),
    "py-async-block": ("Python", "uvicorn 1ワーカー", "/async-block", 300),
    "py-sync-block": ("Python", "uvicorn 1ワーカー", "/sync-block", 300),
    "py-mp-async-block": ("Python", "gunicorn 3ワーカー", "/async-block", 300),
    "py-mp-sync-block": ("Python", "gunicorn 3ワーカー", "/sync-block", 300),
    "go-sleep": ("Go", "GOMAXPROCS=1", "/sleep", 300),
    "py-cpu-async": ("Python", "uvicorn 1ワーカー", "/cpu-async", 10),
    "py-cpu-sync": ("Python", "uvicorn 1ワーカー", "/cpu-sync", 10),
    "go-cpu": ("Go", "GOMAXPROCS=1", "/cpu", 10),
}

STEP_SECONDS = 10  # 負荷の推移を出す間隔


def fmt_ms(value: str) -> str:
    if value in ("", "N/A", "0"):
        return "-"
    v = float(value) / 1000
    return f"{v:.3f}秒" if v < 1 else f"{v:.1f}秒"


def load_timeline(run_id: str) -> list[str]:
    """Locust の履歴から、10秒おきのユーザー数・RPS・応答時間の中央値を出す"""
    path = RESULTS / f"{run_id}_stats_history.csv"
    if not path.exists():
        return []
    rows = [r for r in csv.DictReader(path.open()) if r["Name"] == "Aggregated"]
    if not rows:
        return []
    start = int(rows[0]["Timestamp"])
    lines = ["  経過   ユーザー    RPS   中央値（全体）"]
    next_mark = 0
    for r in rows:
        elapsed = int(r["Timestamp"]) - start
        if elapsed < next_mark:
            continue
        lines.append(
            f"  {elapsed:>3}秒  {int(r['User Count']):>6}  {float(r['Requests/s']):>6.1f}   {fmt_ms(r['50%'])}"
        )
        next_mark = (elapsed // STEP_SECONDS + 1) * STEP_SECONDS
    return lines


def thread_trend(run_id: str) -> str:
    """2秒おきに見た OS スレッド数の、変わり目だけを並べる"""
    path = RESULTS / f"{run_id}.threads"
    if not path.exists():
        return "-"
    samples: list[dict[str, int]] = []
    for line in path.read_text().splitlines():
        if line.startswith("---"):
            samples.append({})
            continue
        parts = line.split(None, 2)
        if samples and len(parts) >= 2 and parts[1].isdigit():
            samples[-1][parts[0]] = int(parts[1])

    trend: list[str] = []
    for sample in samples:
        if len(sample) > 1:
            sample.pop("1", None)  # gunicorn のマスタープロセスは数えない
        if not sample:
            continue
        # ワーカーが複数あるときは「ワーカーごとの値」を / で並べる
        value = " / ".join(str(sample[pid]) for pid in sorted(sample, key=int))
        if not trend or trend[-1] != value:
            trend.append(value)
    return " → ".join(trend) if trend else "-"


def result_line(run_id: str, target: str) -> str:
    path = RESULTS / f"{run_id}_stats.csv"
    stats = {row["Name"]: row for row in csv.DictReader(path.open())}
    total = stats["Aggregated"]
    ping = stats.get("/ping")
    return (
        f"  結果: RPS {float(total['Requests/s']):.1f}"
        f" / {target} の中央値 {fmt_ms(stats[target]['Median Response Time'])}"
        f" / /ping の中央値 {fmt_ms(ping['Median Response Time']) if ping else '-'}"
        f" / 失敗 {total['Failure Count']}"
    )


def main() -> None:
    print("```text")
    first = True
    for run_id, (server, mode, target, users) in SCENARIOS.items():
        if not (RESULTS / f"{run_id}_stats.csv").exists():
            continue
        if not first:
            print()
        first = False
        print(f"==> {run_id}（{server} / {mode} / {target} / 最大{users}ユーザー）")
        for line in load_timeline(run_id):
            print(line)
        print(f"  OS スレッド数の推移: {thread_trend(run_id)}")
        print(result_line(run_id, target))
    print("```")
    print()
    print_table()


if __name__ == "__main__":
    main()
