import os

from locust import HttpUser, between, task

# 負荷をかけるエンドポイント
#   Python: /async-block, /sync-block, /async-wait, /cpu-async, /cpu-sync
#   Go:     /sleep, /cpu
TARGET = os.getenv("TARGET", "/async-block")


class WaitUser(HttpUser):
    """ユーザーの9割：3秒待つ（または CPU 処理をする）エンドポイントを叩く"""

    weight = 9
    wait_time = between(1, 3)

    @task
    def target(self):
        self.client.get(TARGET, name=TARGET)


class PingUser(HttpUser):
    """ユーザーの1割：負荷とは無関係な軽いリクエスト"""

    weight = 1
    wait_time = between(1, 3)

    @task
    def ping(self):
        self.client.get("/ping", name="/ping")
