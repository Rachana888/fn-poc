package main

import (
	"fmt"
	"net/http"
	"os"
	"time"
)

func main() {
	port := os.Getenv("PORT")
	if port == "" {
		port = "9000"
	}
	http.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		host, _ := os.Hostname()
		fmt.Fprintf(w, "hello from user function v1 | host=%s | time=%s\n", host, time.Now().Format(time.RFC3339))
	})
	http.ListenAndServe(":"+port, nil)
}
