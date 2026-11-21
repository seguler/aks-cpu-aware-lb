package main

import (
	"context"
	"crypto/sha256"
	"crypto/subtle"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"log"
	"math"
	"net/http"
	"net/url"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"
)

const freshness = 60 * time.Second
const rateWindow = 30 * time.Second

type metrics struct {
	Timestamp time.Time         `json:"timestamp"`
	Window    string            `json:"window"`
	Usage     map[string]string `json:"usage"`
}

type node struct {
	Metadata struct {
		Labels map[string]string `json:"labels"`
	} `json:"metadata"`
	Status struct {
		Capacity map[string]string `json:"capacity"`
	} `json:"status"`
}

type sample struct {
	CPU       *float64  `json:"nodeCpuUtilization"`
	Timestamp time.Time `json:"metricTimestamp"`
	Window    string    `json:"metricWindow"`
	SKU       string    `json:"sku"`
	Reason    string    `json:"telemetryReason"`
}

type completion struct {
	at     time.Time
	failed bool
}

type state struct {
	mu      sync.Mutex
	current sample
	events  []completion
	start   time.Time
}

func quantity(s string) (float64, error) {
	scale := 1.0
	for suffix, factor := range map[string]float64{"n": 1e-9, "u": 1e-6, "m": 1e-3} {
		if strings.HasSuffix(s, suffix) {
			scale = factor
			s = strings.TrimSuffix(s, suffix)
			break
		}
	}
	v, err := strconv.ParseFloat(s, 64)
	if err != nil || math.IsNaN(v) || math.IsInf(v, 0) || v < 0 {
		return 0, fmt.Errorf("invalid CPU quantity")
	}
	return v * scale, nil
}

func cpuSample(n node, m metrics, now time.Time) (sample, error) {
	s := sample{SKU: n.Metadata.Labels["node.kubernetes.io/instance-type"],
		Timestamp: m.Timestamp, Window: m.Window}
	capacity, err := quantity(n.Status.Capacity["cpu"])
	if err != nil || capacity <= 0 {
		return s, errors.New("invalid node CPU capacity")
	}
	usage, err := quantity(m.Usage["cpu"])
	if err != nil {
		return s, err
	}
	window, err := time.ParseDuration(m.Window)
	if err != nil || window <= 0 || window > freshness || m.Timestamp.IsZero() ||
		now.Sub(m.Timestamp) > freshness || m.Timestamp.After(now.Add(5*time.Second)) {
		return s, errors.New("invalid or stale NodeMetrics interval")
	}
	v := usage / capacity
	if v <= 0 || v > 1 || s.SKU == "" {
		return s, errors.New("node utilization or SKU unavailable/out of range")
	}
	s.CPU = &v
	s.Reason = "ready"
	return s, nil
}

func (s *state) record(now time.Time, failed bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.events = append(s.events, completion{now, failed})
}

func (s *state) report(now time.Time) (sample, float64, float64, string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	retained := s.events[:0]
	for _, e := range s.events {
		if e.at.After(now.Add(-rateWindow)) {
			retained = append(retained, e)
		}
	}
	s.events = retained
	result := s.current
	if result.CPU != nil && now.Sub(result.Timestamp) > freshness {
		result.CPU = nil
		result.Reason = "stale NodeMetrics"
	}
	elapsed := now.Sub(s.start)
	if elapsed > rateWindow {
		elapsed = rateWindow
	}
	if elapsed < rateWindow {
		result.Reason = "request-rate warmup"
	}
	rps, eps := 0.0, 0.0
	if elapsed > 0 {
		rps = float64(len(s.events)) / elapsed.Seconds()
		for _, e := range s.events {
			if e.failed {
				eps += 1 / elapsed.Seconds()
			}
		}
	}
	header := ""
	if result.CPU != nil && elapsed >= rateWindow && rps > 0 {
		b, _ := json.Marshal(map[string]float64{"cpuUtilization": *result.CPU, "rpsFractional": rps, "eps": eps})
		header = "JSON " + string(b)
	} else if elapsed >= rateWindow && rps == 0 {
		result.Reason = "no completed requests in rate window"
	}
	return result, rps, eps, header
}

type kubeClient struct {
	base   string
	token  string
	client *http.Client
}

func (k kubeClient) get(path string, target any) error {
	// Read the projected token on every poll so token rotation works.
	token, err := os.ReadFile(k.token)
	if err != nil {
		return errors.New("cannot read projected service account token")
	}
	req, err := http.NewRequest(http.MethodGet, k.base+path, nil)
	if err != nil {
		return err
	}
	req.Header.Set("Authorization", "Bearer "+strings.TrimSpace(string(token)))
	resp, err := k.client.Do(req)
	if err != nil {
		return errors.New("Kubernetes API request failed")
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("Kubernetes API returned HTTP %d", resp.StatusCode)
	}
	return json.NewDecoder(io.LimitReader(resp.Body, 1<<20)).Decode(target)
}

func (s *state) poll(k kubeClient, name string) {
	for {
		var n node
		var m metrics
		result := sample{Reason: "NodeMetrics unavailable"}
		err := k.get("/api/v1/nodes/"+url.PathEscape(name), &n)
		if err == nil {
			err = k.get("/apis/metrics.k8s.io/v1beta1/nodes/"+url.PathEscape(name), &m)
		}
		result.SKU = n.Metadata.Labels["node.kubernetes.io/instance-type"]
		if err == nil {
			result, err = cpuSample(n, m, time.Now())
		}
		if err != nil {
			log.Printf("telemetry disabled: %v", err)
			result.CPU = nil
			result.Reason = err.Error()
		}
		s.mu.Lock()
		s.current = result
		s.mu.Unlock()
		time.Sleep(10 * time.Second)
	}
}

func work() {
	hash := [32]byte{}
	for i := 0; i < 200000; i++ {
		hash = sha256.Sum256(hash[:])
	}
	// Keep the fixed computation observable, even with future compiler changes.
	if hash[0] == 255 && hash[1] == 255 {
		log.Print("work checksum marker")
	}
}

func handler(s *state, token, name, pod string) http.Handler {
	slots := make(chan struct{}, 32)
	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(http.StatusOK) })
	mux.HandleFunc("/work", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet {
			w.WriteHeader(http.StatusMethodNotAllowed)
			return
		}
		expected := "Bearer " + token
		if subtle.ConstantTimeCompare([]byte(r.Header.Get("Authorization")), []byte(expected)) != 1 {
			w.WriteHeader(http.StatusUnauthorized)
			return
		}
		select {
		case slots <- struct{}{}:
			defer func() { <-slots }()
		default:
			s.record(time.Now(), true)
			http.Error(w, "backend concurrency limit", http.StatusServiceUnavailable)
			return
		}
		work()
		s.record(time.Now(), false)
		m, rps, eps, header := s.report(time.Now())
		if header != "" {
			w.Header().Set("endpoint-load-metrics", header)
		}
		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("Cache-Control", "no-store")
		if err := json.NewEncoder(w).Encode(struct {
			sample
			Node        string  `json:"node"`
			Pod         string  `json:"pod"`
			RPS         float64 `json:"rps"`
			EPS         float64 `json:"eps"`
			ORCAEmitted bool    `json:"orcaEmitted"`
		}{m, name, pod, rps, eps, header != ""}); err != nil {
			log.Print("response write failed")
		}
	})
	return mux
}

func main() {
	burn := flag.Int("burn", 0, "operator-only CPU load duration in seconds (1..1800)")
	workers := flag.Int("workers", 1, "operator-only CPU workers (1..8)")
	flag.Parse()
	if *burn != 0 {
		if *burn < 1 || *burn > 1800 || *workers < 1 || *workers > 8 {
			log.Fatal("burn duration/workers outside allowed bounds")
		}
		ctx, cancel := context.WithTimeout(context.Background(), time.Duration(*burn)*time.Second)
		defer cancel()
		var wg sync.WaitGroup
		for i := 0; i < *workers; i++ {
			wg.Add(1)
			go func() {
				defer wg.Done()
				for ctx.Err() == nil {
					work()
				}
			}()
		}
		wg.Wait()
		return
	}
	token := os.Getenv("DEMO_TOKEN")
	name := os.Getenv("NODE_NAME")
	if len(token) < 32 || name == "" {
		log.Fatal("NODE_NAME and a DEMO_TOKEN of at least 32 characters are required")
	}
	const dir = "/var/run/secrets/kubernetes.io/serviceaccount/"
	ca, err := os.ReadFile(dir + "ca.crt")
	if err != nil {
		log.Fatal("cannot read Kubernetes CA")
	}
	roots := x509.NewCertPool()
	if !roots.AppendCertsFromPEM(ca) {
		log.Fatal("invalid Kubernetes CA")
	}
	k := kubeClient{base: "https://kubernetes.default.svc", token: dir + "token",
		client: &http.Client{Timeout: 5 * time.Second, Transport: &http.Transport{
			TLSClientConfig: &tls.Config{RootCAs: roots, MinVersion: tls.VersionTLS12}}}}
	s := &state{start: time.Now(), current: sample{Reason: "NodeMetrics warmup"}}
	go s.poll(k, name)
	server := &http.Server{Addr: ":8080", Handler: handler(s, token, name, os.Getenv("POD_NAME")),
		ReadHeaderTimeout: 5 * time.Second, WriteTimeout: 30 * time.Second, IdleTimeout: 60 * time.Second}
	log.Fatal(server.ListenAndServe())
}
