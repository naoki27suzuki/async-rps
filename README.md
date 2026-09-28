# FastAPI、Goの待ち方と実行モデルの検証コード

同じ「3秒の待ち」と「CPU 処理」を、次の2つで比べます。

- **Python（FastAPI）**：書き方（`async def` / `def`）と起動方法（uvicorn 1ワーカー / gunicorn 3ワーカー）を組み合わせる
- **Go**：同期的に `time.Sleep` と書き、`GOMAXPROCS=1` で動かす

## すぐ試す

以下で実行可能で約10分ほどかかる。

```bash
DURATION=45s ./scripts/run_all.sh
```

全9構成を順番に測り、最後に結果を表にまとめて出します。

- 始めるときに、`results/` にある前回の結果を消します
- 途中で Ctrl+C を押すと、その時点で止まります。表は出ないので、最初からやり直してください
- 失敗したリクエストがあっても、止めずに次の構成へ進みます。同期で待つ構成（`py-async-block` など）では、ループが止まっている間に接続が切られ、`Connection reset by peer` で失敗することがあります

### 進み具合を見る

計測中に別のターミナルで `watch.sh` を動かすと、進み具合を2秒ごとに表示し直します。`run_all.sh` より先に起動しておいても構いません。

```bash
./scripts/watch.sh
```

```text
12:52:54  （Ctrl+C で終了）

■ 計測中
  構成     : py-sync-block（3/9）
  サーバ   : python（uvicorn 1ワーカー）
  TARGET   : /sync-block
  ユーザー : 最大 300（経過 21秒 / 45s）

■ OS スレッド数（NLWP）
    PID NLWP COMMAND
      1   46 /usr/local/bin/python3.12 /usr/local/bin/uvicorn main:app --host 0.0.0.0 --port 8000 --workers 1

■ 終わった構成（2/9、新しい順）
  12:50:26  py-async-block
  12:49:54  py-async-wait
```

| 項目 | 内容 |
|---|---|
| 計測中 | いま計測している構成と、その ID が何番目か。構成を切り替えている間は「負荷はかかっていません」と出る |
| OS スレッド数 | サーバのプロセスごとのスレッド数（`ps` の NLWP）。gunicorn はマスターと3つのワーカーが並ぶ |
| 終わった構成 | 結果の CSV が出そろった構成と、終わった時刻 |

`watch.sh` は macOS の `date` と `ls` のオプションを使っています。Linux では時刻の表示が崩れることがあります。

表示の間隔は `INTERVAL` で変えられます（既定は2秒）。1回だけ表示するなら `ONCE=1` を付けます。

```bash
INTERVAL=5 ./scripts/watch.sh
```

```bash
ONCE=1 ./scripts/watch.sh
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
│   ├── watch.sh            # 計測の進み具合を表示する
│   ├── report.py           # ログを作る
│   └── summarize.py        # results/ を表にまとめる
└── results/                # 計測結果（Locust の CSV・ログ、スレッド数）
```

## 計測する構成

| ID | 構成 | サーバ | 起動方法 | エンドポイント | ユーザー数 |
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

数値を計測したときの環境です。

| 項目 | 値 |
|---|---|
| マシン / OS | macOS |
| Docker | （記入） |
| Python | 3.12 |
| FastAPI / uvicorn / gunicorn | （記入：`docker compose exec python pip freeze`） |
| Go | 1.24 |
| Locust | （記入：`docker compose run --rm locust --version`） |


### 負荷中のスレッド数を見る

`watch.sh` を使わずに直接見る場合は、負荷をかけている間に、別のターミナルで実行します。`NLWP` 列が、プロセスごとの OS スレッド数です。

`run_all.sh` は Compose のプロジェクト名を `afbench` にしているので、`-p afbench` を付けてください。

```bash
docker compose -p afbench exec python ps -eo pid,nlwp,args
```

```bash
docker compose -p afbench exec go ps -eo pid,nlwp,args
```

OS スレッド数には、イベントループやスレッドプール以外のスレッドも含まれます。このため、何もしていないときから数本あります（uvicorn 1ワーカーで6本程度）。スレッドプールで増えた分を見るときは、負荷をかける前の値と比べてください。

### 後片付け

```bash
docker compose --profile load down
```

## CPU 処理の重さを合わせる

CPU 処理を「1コアで約0.4秒」にしています。ループの回数は環境変数で変えられるので、負荷をかけずに1回叩いて、0.4秒前後になるよう調整してください。

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

### ログ作成

`scripts/report.py` は、構成ごとの経過をログの形にまとめ、最後に上の表を付けます。出力は Markdownです。

```bash
python3 scripts/report.py > results/report.md
```

```text
==> py-async-block（Python / uvicorn 1ワーカー / /async-block / 最大300ユーザー）
  経過   ユーザー    RPS   中央値（全体）
    0秒       0     0.0   -
   10秒     100     0.3   6.0秒
   20秒     200     0.4   6.5秒
   30秒     300     0.3   9.2秒
   40秒     300     0.3   13.0秒
  OS スレッド数の推移: 6
  結果: RPS 0.4 / /async-block の中央値 13.0秒 / /ping の中央値 9.1秒 / 失敗 1
```

| 行 | 内容 |
|---|---|
| 経過ごとの行 | Locust の履歴（`<ID>_stats_history.csv`）から10秒おきに取り出した、ユーザー数・その時点の RPS・全リクエストの応答時間の中央値 |
| OS スレッド数の推移 | 2秒おきに見たスレッド数の変わり目。gunicorn はワーカーごとの値を `/` で並べる |
| 結果 | 計測全体の RPS と、対象・`/ping` それぞれの応答時間の中央値 |

## 検証の限界

- 同期 I/O の代わりに `time.sleep`、CPU 処理の代わりに単純なループを使っています。実際の DB アクセスとは、細かい挙動が異なる可能性があります
- 数値はマシンや Docker の設定で変わります。
