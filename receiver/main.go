package main

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httputil"
	"net/url"
	"os"
	"os/exec"
	"strings"
	"sync"
	"time"
)

var (
	mu     sync.Mutex
	child  *exec.Cmd
	sum    string
	loaded bool
)

const binPath = "/srv/fn/bin"

func startChild() error {
	if child != nil && child.Process != nil {
		child.Process.Kill()
		child.Wait()
	}
	c := exec.Command(binPath)
	c.Env = append(os.Environ(), "PORT=9000")
	// FROM scratch has no /dev/null; a nil Stdin makes Go open it and fail.
	c.Stdin = strings.NewReader("")
	c.Stdout, c.Stderr = os.Stdout, os.Stderr
	if err := c.Start(); err != nil {
		return err
	}
	child = c
	for i := 0; i < 100; i++ { // wait up to 10s for the function to listen
		conn, err := net.DialTimeout("tcp", "127.0.0.1:9000", 100*time.Millisecond)
		if err == nil {
			conn.Close()
			return nil
		}
		time.Sleep(100 * time.Millisecond)
	}
	return fmt.Errorf("function never listened on :9000")
}

func swap(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "POST only", 405)
		return
	}
	body, err := io.ReadAll(r.Body)
	if err != nil || len(body) == 0 {
		http.Error(w, "empty body", 400)
		return
	}
	mu.Lock()
	defer mu.Unlock()
	os.MkdirAll("/srv/fn", 0755)
	if err := os.WriteFile(binPath+".new", body, 0755); err != nil {
		http.Error(w, err.Error(), 500)
		return
	}
	os.Rename(binPath+".new", binPath)
	if err := startChild(); err != nil {
		http.Error(w, err.Error(), 500)
		return
	}
	h := sha256.Sum256(body)
	sum, loaded = hex.EncodeToString(h[:]), true
	fmt.Fprintf(w, `{"loaded":true,"sha256":"%s","bytes":%d}`+"\n", sum, len(body))
}

func status(w http.ResponseWriter, _ *http.Request) {
	mu.Lock()
	defer mu.Unlock()
	fmt.Fprintf(w, `{"loaded":%v,"sha256":"%s"}`+"\n", loaded, sum)
}

func main() {
	// control plane of the mailbox
	ctl := http.NewServeMux()
	ctl.HandleFunc("/swap", swap)
	ctl.HandleFunc("/status", status)
	go http.ListenAndServe(":8081", ctl)

	// traffic port: proxy to the function once loaded
	target, _ := url.Parse("http://127.0.0.1:9000")
	proxy := httputil.NewSingleHostReverseProxy(target)
	http.ListenAndServe(":8080", http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		ok := loaded
		mu.Unlock()
		if !ok {
			http.Error(w, "no function loaded", 503)
			return
		}
		proxy.ServeHTTP(w, r)
	}))
}
