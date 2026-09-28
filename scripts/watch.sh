#!/usr/bin/env bash
# run_all.sh の実行中に別のターミナルで動かし、計測の進み具合を2秒ごとに表示する
#   - いま計測中の構成（サーバ・起動方法・TARGET・ユーザー数）
#   - サーバのプロセスごとの OS スレッド数（NLWP）
#   - 計測が終わった構成
set -uo pipefail
cd "$(dirname "$0")/.."

export COMPOSE_PROJECT_NAME=afbench
INTERVAL="${INTERVAL:-2}"
TOTAL=9

# 実行中の Locust コンテナから、環境変数の値を読む
locust_env() {
  local cid=$1 key=$2
  docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$cid" 2>/dev/null |
    sed -n "s/^${key}=//p"
}

# 実行中の Locust コンテナのコマンドから、オプションの値を読む（-u, -t）
locust_opt() {
  local cid=$1 opt=$2
  docker inspect -f '{{range .Config.Cmd}}{{println .}}{{end}}' "$cid" 2>/dev/null |
    awk -v o="$opt" 'prev == o {print; exit} {prev = $0}'
}

show() {
  echo "$(date '+%H:%M:%S')  （Ctrl+C で終了）"
  echo

  # 計測中の構成
  local svc="" mode=""
  if [ -n "$(docker compose ps -q --status running python 2>/dev/null)" ]; then
    svc=python
    if docker compose exec -T python ps -eo args 2>/dev/null </dev/null | grep -q gunicorn; then
      mode="gunicorn 3ワーカー"
    else
      mode="uvicorn 1ワーカー"
    fi
  elif [ -n "$(docker compose ps -q --status running go 2>/dev/null)" ]; then
    svc=go
    mode="GOMAXPROCS=$(docker compose exec -T go printenv GOMAXPROCS 2>/dev/null </dev/null | tr -d '\r')"
  fi

  local cid current=""
  cid=$(docker ps -q --filter "label=com.docker.compose.project=afbench" \
    --filter "label=com.docker.compose.service=locust" | head -1)

  echo "■ 計測中"
  if [ -n "$cid" ]; then
    local started elapsed
    started=$(docker inspect -f '{{.State.StartedAt}}' "$cid" | cut -d. -f1)
    elapsed=$(( $(date -u +%s) - $(date -u -j -f '%Y-%m-%dT%H:%M:%S' "$started" +%s 2>/dev/null || date -u -d "$started" +%s) ))
    current=$(basename "$(locust_opt "$cid" --csv)")
    echo "  構成     : ${current}（$(( $(ls results/*_stats.csv 2>/dev/null | grep -v "/${current}_stats.csv" | wc -l) + 1 ))/${TOTAL}）"
    echo "  サーバ   : ${svc:--}（${mode:--}）"
    echo "  TARGET   : $(locust_env "$cid" TARGET)"
    echo "  ユーザー : 最大 $(locust_opt "$cid" -u)（経過 ${elapsed}秒 / $(locust_opt "$cid" -t)）"
  else
    echo "  負荷はかかっていません（構成の切り替え中、または計測前後）"
  fi
  echo

  # スレッド数
  echo "■ OS スレッド数（NLWP）"
  if [ -n "$svc" ]; then
    docker compose exec -T "$svc" ps -eo pid,nlwp,args 2>/dev/null </dev/null |
      grep -E "NLWP|uvicorn|gunicorn|/bench" | sed 's/^/  /'
  else
    echo "  サーバは動いていません"
  fi
  echo

  # 終わった構成（新しい順。計測中の構成は除く）
  local finished
  finished=$(ls -lt -D '%H:%M:%S' results/*_stats.csv 2>/dev/null |
    awk '{print "  " $6 "  " $7}' | sed 's|results/||; s|_stats.csv||' |
    grep -v " ${current:-__none__}$" || true)
  echo "■ 終わった構成（$(printf '%s' "$finished" | grep -c . || true)/${TOTAL}、新しい順）"
  [ -n "$finished" ] && echo "$finished"
}

if [ "${ONCE:-0}" = 1 ]; then
  show
  exit 0
fi

while :; do
  out=$(show)
  clear
  echo "$out"
  sleep "$INTERVAL"
done
