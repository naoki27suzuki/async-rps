#!/usr/bin/env bash
# 全構成を順番に計測し、results/ に Locust の CSV とスレッド数を保存する
set -euo pipefail
cd "$(dirname "$0")/.."

export COMPOSE_PROJECT_NAME=afbench
export DURATION="${DURATION:-45s}"
export SPAWN_RATE="${SPAWN_RATE:-10}"

UVICORN_1="uvicorn main:app --host 0.0.0.0 --port 8000 --workers 1"
GUNICORN_3="gunicorn main:app -w 3 -k uvicorn.workers.UvicornWorker -b 0.0.0.0:8000"

# ID | サーバ | 起動方法 | TARGET | ユーザー数
SCENARIOS="
py-async-wait|python|uvicorn1|/async-wait|300
py-async-block|python|uvicorn1|/async-block|300
py-sync-block|python|uvicorn1|/sync-block|300
py-mp-async-block|python|gunicorn3|/async-block|300
py-mp-sync-block|python|gunicorn3|/sync-block|300
py-cpu-async|python|uvicorn1|/cpu-async|10
py-cpu-sync|python|uvicorn1|/cpu-sync|10
go-sleep|go|gomaxprocs1|/sleep|300
go-cpu|go|gomaxprocs1|/cpu|10
"

wait_ready() {
  for _ in $(seq 1 60); do
    curl -sf "localhost:$1/ping" >/dev/null && return 0
    sleep 1
  done
  echo "サーバが起動しませんでした（port ${1}）" >&2
  exit 1
}

# 負荷中のスレッド数を2秒おきに記録する
sample_threads() {
  local svc=$1 out=$2
  while :; do
    echo "---" >>"$out"
    docker compose exec -T "$svc" ps -eo pid=,nlwp=,args= 2>/dev/null |
      grep -E "uvicorn|gunicorn|/bench" >>"$out" || true
    sleep 2
  done
}

# Ctrl+C で止めたときも、スレッド数を記録する裏のループを残さない
sampler=""
cleanup() {
  if [ -n "$sampler" ]; then kill "$sampler" 2>/dev/null || true; fi
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT TERM

docker compose build python go >/dev/null

# 前回の結果を消してから始める（watch.sh で進み具合を数えられるように）
mkdir -p results
find results -type f ! -name .keep -delete

# docker が標準入力を読んでもシナリオの読み込みが崩れないよう、fd 3 から読む
while IFS='|' read -r id svc mode target users <&3; do
  [ -z "$id" ] && continue
  echo "==> ${id}（${svc} / ${mode} / ${target} / ${users}ユーザー）"
  rm -f "results/${id}"_*.csv "results/${id}.threads"

  # 毎回コンテナを作り直し、スレッドプールなどの状態をリセットする
  docker compose stop python go >/dev/null 2>&1 || true
  if [ "$svc" = python ]; then
    if [ "$mode" = gunicorn3 ]; then cmd=$GUNICORN_3; else cmd=$UVICORN_1; fi
    APP_CMD="$cmd" docker compose up -d --force-recreate python >/dev/null
    wait_ready 8000
    host=http://python:8000
  else
    GOMAXPROCS=1 docker compose up -d --force-recreate go >/dev/null
    wait_ready 8001
    host=http://go:8000
  fi

  sample_threads "$svc" "results/${id}.threads" &
  sampler=$!
  # Locust は失敗が1件でもあると終了コード1を返す。
  # 同期で待つ構成では接続が切られることもあるので、止めずに次の構成へ進む
  status=0
  RUN_ID=$id TARGET=$target USERS=$users HOST=$host \
    docker compose --profile load run --rm locust >"results/${id}.log" 2>&1 </dev/null || status=$?
  if [ "$status" -ne 0 ]; then
    echo "    失敗したリクエストがあります（終了コード ${status}）。詳しくは results/${id}.log を見てください"
  fi
  if [ ! -f "results/${id}_stats.csv" ]; then
    echo "    結果の CSV がありません。Locust が起動できなかった可能性があります" >&2
  fi
  kill "$sampler" 2>/dev/null || true
  wait "$sampler" 2>/dev/null || true
  sampler=""
done 3<<<"$SCENARIOS"

docker compose --profile load down >/dev/null 2>&1
python3 scripts/summarize.py
python3 scripts/report.py >results/report.md
