# FastAPI の待ち方と実行モデルの検証コード

記事「FastAPI はどこで待たされていたのか ― イベントループ・スレッド・プロセスで整理する」の検証に使ったコード一式です。

同じ「3秒の待ち」と「CPU 処理」を、次の2つで比べます。

- **Python（FastAPI）**：書き方（`async def` / `def`）と起動方法（uvicorn 1ワーカー / gunicorn 3ワーカー）を組み合わせる
- **Go**：同期的に `time.Sleep` と書き、`GOMAXPROCS=1` で動かす

## すぐ試す

Docker（Compose v2）と `curl`、`python3` があれば動きます。

```bash
./scripts/run_all.sh
```

全9構成を順番に測り、最後に記事と同じ形の表を出します。1構成あたり約1分、全体で10分ほどかかります。短く試すなら、計測時間を縮めてください。

```bash
DURATION=15s ./scripts/run_all.sh
```

## ファイル構成

```text
.
├── compose.yaml            # python / go / locust
├── python/                 # FastAPI（Python 3.12）
│   ├── main.py
│   ├── requirements.txt
│   └── Dockerfile
├── go/                     # Go 1.24（標準ライブラリのみ）
│   ├── main.go
│   ├── go.mod
│   └── Dockerfile
├── locust/locustfile.py    # 負荷シナリオ
├── scripts/
│   ├── run_all.sh          # 全構成を計測する
│   └── summarize.py        # results/ を表にまとめる
└── results/                # 計測結果（Locust の CSV・ログ、スレッド数）
```

## 計測する構成

| ID | 記事の構成 | サーバ | 起動方法 | エンドポイント | ユーザー数 |
|---|---|---|---|---|---|
| `py-async-wait` | シングルプロセス × シングルスレッド（非同期で待つ） | Python | uvicorn 1ワーカー | `/async-wait` | 300 |
| `py-async-block` | シングルプロセス × シングルスレッド（同期で待つ） | Python | uvicorn 1ワーカー | `/async-block` | 300 |
| `py-sync-block` | シングルプロセス × マルチスレッド | Python | uvicorn 1ワーカー | `/sync-block` | 300 |
| `py-mp-async-block` | マルチプロセス × シングルスレッド | Python | gunicorn 3ワーカー | `/async-block` | 300 |
| `py-mp-sync-block` | マルチプロセス × マルチスレッド | Python | gunicorn 3ワーカー | `/sync-block` | 300 |
| `go-sleep` | Go では書き分けが要らない | Go | `GOMAXPROCS=1` | `/sleep` | 300 |
| `py-cpu-async` | CPU 処理（`async def`） | Python | uvicorn 1ワーカー | `/cpu-async` | 10 |
| `py-cpu-sync` | CPU 処理（`def`） | Python | uvicorn 1ワーカー | `/cpu-sync` | 10 |
| `go-cpu` | （参考）Go の CPU 処理 | Go | `GOMAXPROCS=1` | `/cpu` | 10 |

`go-cpu` は記事には載せていない参考値です。

## エンドポイント

### Python（`python/main.py`、ポート 8000）

| パス | 書き方 | 役割 |
|---|---|---|
| `/async-block` | `async def` + `time.sleep(3)` | 同期ドライバで DB を待つ代わり（ループが止まる） |
| `/sync-block` | `def` + `time.sleep(3)` | スレッドプールのスレッドで待つ |
| `/async-wait` | `async def` + `await asyncio.sleep(3)` | 非同期ドライバで `await` する代わり |
| `/cpu-async` | `async def` + CPU 処理 | イベントループのスレッドで計算する |
| `/cpu-sync` | `def` + CPU 処理 | スレッドプールのスレッドで計算する |
| `/ping` | `async def` | 負荷とは無関係な軽いリクエスト |

レスポンスには、処理したプロセスの PID、スレッド名、Python のスレッド数が入ります。

```bash
curl -s localhost:8000/sync-block
```

```json
{"pid":1,"thread":"AnyIO worker thread","python_threads":2}
```

### Go（`go/main.go`、ポート 8001）

| パス | 書き方 | 役割 |
|---|---|---|
| `/sleep` | `time.Sleep(3 * time.Second)` | 同期的に待つ（`await` のような印は書かない） |
| `/cpu` | CPU 処理 | 計算する |
| `/ping` | - | 負荷とは無関係な軽いリクエスト |

レスポンスには、PID、`GOMAXPROCS`、goroutine の数、OS スレッドの数が入ります。負荷中に叩くと、goroutine は数百あるのに、OS スレッドは十数本程度にとどまることが分かります（下の例は300ユーザーの負荷中の値）。goroutine には、待っているリクエストのほかに、HTTP の接続ごとの goroutine も含まれます。

```bash
curl -s localhost:8001/ping
```

```json
{"gomaxprocs":1,"goroutines":451,"os_threads":13,"pid":1,"result":0}
```

## 負荷の条件

| 項目 | 3秒の待ち | CPU 処理 |
|---|---|---|
| ユーザー数 | 300 | 10 |
| 増やし方 | 毎秒10ユーザー | 毎秒10ユーザー |
| 計測時間 | 45秒 | 45秒 |
| ユーザーの内訳 | 9割が対象のエンドポイント、1割が `/ping` | 同左 |
| `wait_time` | `between(1, 3)` | 同左 |
| サーバの CPU | 2コアに制限（`cpus: "2"`） | 同左 |

- RPS は、ランプアップ中も含めた計測時間全体の、全エンドポイントの合計です
- Locust も同じマシンで動かしているので、Locust 自身も CPU を使います
- 構成ごとにサーバのコンテナを作り直し、前の計測のスレッドが残らないようにしています

## 計測環境

記事の数値を計測したときの環境です。

| 項目 | 値 |
|---|---|
| マシン / OS | （記入） |
| Docker | （記入） |
| Python | 3.12 |
| FastAPI / uvicorn / gunicorn | （記入：`docker compose exec python pip freeze`） |
| Go | 1.24 |
| Locust | （記入：`docker compose run --rm locust --version`） |

## 手で動かす

`run_all.sh` を使わずに、1構成ずつ測ることもできます。

### Python

```bash
# uvicorn 1ワーカー（シングルプロセス）
docker compose up -d --build python
```

```bash
# gunicorn 3ワーカー（マルチプロセス）
APP_CMD="gunicorn main:app -w 3 -k uvicorn.workers.UvicornWorker -b 0.0.0.0:8000" docker compose up -d --build --force-recreate python
```

```bash
TARGET=/async-block docker compose --profile load run --rm locust
```

```bash
# CPU 処理は10ユーザー
TARGET=/cpu-sync USERS=10 docker compose --profile load run --rm locust
```

### Go

```bash
docker compose up -d --build go
```

```bash
TARGET=/sleep HOST=http://go:8000 docker compose --profile load run --rm locust
```

`GOMAXPROCS` は環境変数で変えられます（既定は1）。

```bash
GOMAXPROCS=2 docker compose up -d --force-recreate go
```

### 負荷中のスレッド数を見る

負荷をかけている間に、別のターミナルで実行します。`NLWP` 列が、プロセスごとの OS スレッド数です。

```bash
docker compose exec python ps -eo pid,nlwp,args
```

```bash
docker compose exec go ps -eo pid,nlwp,args
```

OS スレッド数には、イベントループやスレッドプール以外のスレッドも含まれます。このため、何もしていないときから数本あります（uvicorn 1ワーカーで6本程度）。スレッドプールで増えた分を見るときは、負荷をかける前の値と比べてください。

### 後片付け

```bash
docker compose --profile load down
```

## CPU 処理の重さを合わせる

記事では、CPU 処理を「1コアで約0.4秒」にしています。ループの回数は環境変数で変えられるので、負荷をかけずに1回叩いて、0.4秒前後になるよう調整してください。

```bash
time curl -s localhost:8000/cpu-sync
```

```bash
PY_CPU_LOOPS=15000000 docker compose up -d --force-recreate python
```

| 変数 | 対象 | 既定値 |
|---|---|---|
| `PY_CPU_LOOPS` | Python の `/cpu-async`、`/cpu-sync` | 10,000,000 |
| `GO_CPU_LOOPS` | Go の `/cpu` | 1,000,000,000 |

`run_all.sh` にも同じ変数を渡せます。

```bash
PY_CPU_LOOPS=15000000 GO_CPU_LOOPS=1300000000 ./scripts/run_all.sh
```

## 計測結果の見方

`scripts/summarize.py` は、`results/` の CSV から次の表を出します。

| 列 | 意味 |
|---|---|
| 負荷中の OS スレッド数 | 2秒おきに `ps` で見た、プロセスごとの最大値。gunicorn はマスターを除いたワーカーの数を「× 3プロセス」と表示する |
| RPS | 全エンドポイントの合計 |
| 対象の応答時間（中央値） | 3秒待つ（または CPU 処理をする）エンドポイント |
| `/ping` の応答時間（中央値） | 無関係な軽いリクエストが、どれだけ巻き込まれたか |

Locust の生の結果は `results/<ID>_stats.csv` と `results/<ID>.log` にあります。

## 検証の限界

- 同期 I/O の代わりに `time.sleep`、CPU 処理の代わりに単純なループを使っています。実際の DB アクセスとは、細かい挙動が異なる可能性があります
- 数値はマシンや Docker の設定で変わります。記事の数値と同じ値になるとは限らないので、構成どうしの差を見てください
