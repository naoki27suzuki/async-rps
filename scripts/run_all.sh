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

docker compose build python go >/dev/null
mkdir -p results

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
  RUN_ID=$id TARGET=$target USERS=$users HOST=$host \
    docker compose --profile load run --rm locust >"results/${id}.log" 2>&1 </dev/null
  kill "$sampler" 2>/dev/null || true
  wait "$sampler" 2>/dev/null || true
done 3<<<"$SCENARIOS"

docker compose --profile load down >/dev/null 2>&1
python3 scripts/summarize.py
