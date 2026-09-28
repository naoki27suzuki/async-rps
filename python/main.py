import asyncio
import os
import threading
import time

from fastapi import FastAPI

app = FastAPI()

WAIT_SECONDS = 3
# 1回あたり約0.4秒（1コア）になる回数。環境に合わせて CPU_LOOPS で調整する
CPU_LOOPS = int(os.getenv("CPU_LOOPS", "10000000"))


def where() -> dict:
    """どのプロセス・スレッドで処理されたかを返す"""
    return {
        "pid": os.getpid(),
        "thread": threading.current_thread().name,
        "python_threads": threading.active_count(),
    }


def burn_cpu() -> int:
    total = 0
    for i in range(CPU_LOOPS):
        total += i
    return total


# --- I/O 待ちの代わり ---------------------------------------------------

@app.get("/async-block")
async def async_block():
    time.sleep(WAIT_SECONDS)  # ❌ 順番を譲らずに待つ（ループが止まる）
    return where()


@app.get("/sync-block")
def sync_block():
    time.sleep(WAIT_SECONDS)  # スレッドプールのスレッドで待つ
    return where()


@app.get("/async-wait")
async def async_wait():
    await asyncio.sleep(WAIT_SECONDS)  # ✅ await で順番を譲って待つ
    return where()


# --- CPU 処理 -------------------------------------------------------------

@app.get("/cpu-async")
async def cpu_async():
    burn_cpu()  # イベントループのスレッドで計算する
    return where()


@app.get("/cpu-sync")
def cpu_sync():
    burn_cpu()  # スレッドプールのスレッドで計算する
    return where()


# --- 負荷とは無関係な軽いリクエスト ------------------------------------------

@app.get("/ping")
async def ping():
    return where()
