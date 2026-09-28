package main

import (
	"bufio"
	"encoding/json"
	"log"
	"net/http"
	"os"
	"runtime"
	"strconv"
	"strings"
	"time"
)

const waitSeconds = 3

// 1回あたり約0.4秒（1コア）になる回数。環境に合わせて CPU_LOOPS で調整する
var cpuLoops = envInt("CPU_LOOPS", 1_000_000_000)

func envInt(key string, def int) int {
	if v, err := strconv.Atoi(os.Getenv(key)); err == nil {
		return v
	}
	return def
}

// osThreads は、このプロセスの OS スレッド数を /proc から読む
func osThreads() int {
	f, err := os.Open("/proc/self/status")
	if err != nil {
		return -1
	}
	defer f.Close()
	s := bufio.NewScanner(f)
	for s.Scan() {
		if n, ok := strings.CutPrefix(s.Text(), "Threads:"); ok {
			v, _ := strconv.Atoi(strings.TrimSpace(n))
			return v
		}
	}
	return -1
}

// where は、どのプロセスで処理されたかと、goroutine・OS スレッドの数を返す
func where(w http.ResponseWriter, extra int) {
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]int{
		"pid":        os.Getpid(),
		"gomaxprocs": runtime.GOMAXPROCS(0),
		"goroutines": runtime.NumGoroutine(),
		"os_threads": osThreads(),
		"result":     extra,
	})
}

func burnCPU() int {
	total := 0
	for i := 0; i < cpuLoops; i++ {
		total += i
	}
	return total
}

func main() {
	// Python の time.sleep と同じく、同期的に待つ。await のような印は書かない
	http.HandleFunc("/sleep", func(w http.ResponseWriter, r *http.Request) {
		time.Sleep(waitSeconds * time.Second)
		where(w, 0)
	})
	http.HandleFunc("/cpu", func(w http.ResponseWriter, r *http.Request) {
		where(w, burnCPU())
	})
	http.HandleFunc("/ping", func(w http.ResponseWriter, r *http.Request) {
		where(w, 0)
	})
	log.Fatal(http.ListenAndServe(":8000", nil))
}
