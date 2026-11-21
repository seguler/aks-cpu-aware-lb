package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"math"
	"net/http"
	"os"
	"sort"
	"sync"
	"time"
)

type response struct {
	Node      string    `json:"node"`
	SKU       string    `json:"sku"`
	CPU       *float64  `json:"nodeCpuUtilization"`
	Timestamp time.Time `json:"metricTimestamp"`
	ORCA      bool      `json:"orcaEmitted"`
}

type aggregate struct {
	SKU          string  `json:"sku"`
	Requests     int     `json:"requests"`
	Share        float64 `json:"sharePercent"`
	CPU          float64 `json:"meanNodeCpuPercent"`
	CPUSamples   int     `json:"distinctCpuSamples"`
	ORCARequests int     `json:"orcaEmittedRequests"`
	samples      map[time.Time]float64
}

type result struct {
	Mode           string                `json:"mode"`
	Concurrency    int                   `json:"concurrency"`
	Seconds        float64               `json:"elapsedSeconds"`
	Success        int                   `json:"successfulRequests"`
	Errors         int                   `json:"errors"`
	ErrorKinds     map[string]int        `json:"errorKinds"`
	RPS            float64               `json:"successfulRps"`
	P50            float64               `json:"p50Milliseconds"`
	P95            float64               `json:"p95Milliseconds"`
	Nodes          map[string]*aggregate `json:"nodes"`
	GatewayHeaders int                   `json:"unexpectedOrcaHeaders"`
}

func percentile(values []float64, p float64) float64 {
	if len(values) == 0 {
		return 0
	}
	return values[int(math.Ceil(p*float64(len(values))))-1]
}

func run(endpoint, token, mode string, duration time.Duration, concurrency int) result {
	ctx, cancel := context.WithTimeout(context.Background(), duration)
	defer cancel()
	client := &http.Client{Timeout: 10 * time.Second, Transport: &http.Transport{
		MaxIdleConns: concurrency, MaxIdleConnsPerHost: concurrency}}
	defer client.CloseIdleConnections()
	output := result{Mode: mode, Concurrency: concurrency, Nodes: map[string]*aggregate{}, ErrorKinds: map[string]int{}}
	var mu sync.Mutex
	var wg sync.WaitGroup
	var latencies []float64
	start := time.Now()
	for i := 0; i < concurrency; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for ctx.Err() == nil {
				req, err := http.NewRequestWithContext(ctx, "GET", endpoint, nil)
				if err != nil {
					panic(err) // URL validated before run.
				}
				req.Header.Set("Authorization", "Bearer "+token)
				before := time.Now()
				resp, err := client.Do(req)
				var body response
				kind := ""
				hasHeader := false
				if err != nil {
					if ctx.Err() != nil {
						break
					}
					kind = "transport"
				} else {
					hasHeader = resp.Header.Get("endpoint-load-metrics") != ""
					if resp.StatusCode != 200 {
						kind = fmt.Sprintf("http-%d", resp.StatusCode)
					} else if err := json.NewDecoder(resp.Body).Decode(&body); err != nil || body.Node == "" || body.SKU == "" {
						kind = "invalid-response"
					}
					resp.Body.Close()
					if kind != "" && ctx.Err() != nil {
						break
					}
				}
				mu.Lock()
				latencies = append(latencies, float64(time.Since(before).Microseconds())/1000)
				if kind != "" {
					output.Errors++
					output.ErrorKinds[kind]++
				} else {
					output.Success++
					a := output.Nodes[body.Node]
					if a == nil {
						a = &aggregate{SKU: body.SKU, samples: map[time.Time]float64{}}
						output.Nodes[body.Node] = a
					}
					a.Requests++
					if body.ORCA {
						a.ORCARequests++
					}
					if body.CPU != nil && !body.Timestamp.IsZero() {
						a.samples[body.Timestamp] = *body.CPU
					}
				}
				if hasHeader {
					output.GatewayHeaders++
				}
				mu.Unlock()
			}
		}()
	}
	wg.Wait()
	output.Seconds = time.Since(start).Seconds()
	output.RPS = float64(output.Success) / output.Seconds
	sort.Float64s(latencies)
	output.P50, output.P95 = percentile(latencies, 0.5), percentile(latencies, 0.95)
	names := make([]string, 0, len(output.Nodes))
	for name := range output.Nodes {
		names = append(names, name)
	}
	sort.Strings(names)
	sanitized := map[string]*aggregate{}
	for i, name := range names {
		a := output.Nodes[name]
		a.Share = 100 * float64(a.Requests) / float64(output.Success)
		a.CPUSamples = len(a.samples)
		for _, cpu := range a.samples {
			a.CPU += 100 * cpu / float64(a.CPUSamples)
		}
		sanitized[fmt.Sprintf("node-%d", i+1)] = a
	}
	output.Nodes = sanitized
	return output
}

func main() {
	endpoint := flag.String("url", "", "gateway URL ending in /work")
	mode := flag.String("mode", "load-aware", "label for current gateway strategy")
	duration := flag.Duration("duration", 90*time.Second, "measurement time (10s..10m)")
	warmup := flag.Duration("warmup", 60*time.Second, "discarded warmup (30s..5m)")
	concurrency := flag.Int("concurrency", 32, "closed-loop clients (1..128)")
	flag.Parse()
	token := os.Getenv("DEMO_TOKEN")
	req, err := http.NewRequest("GET", *endpoint, nil)
	if err != nil || req.URL.Host == "" || (req.URL.Scheme != "http" && req.URL.Scheme != "https") ||
		len(token) < 32 || *duration < 10*time.Second || *duration > 10*time.Minute ||
		*warmup < 30*time.Second || *warmup > 5*time.Minute || *concurrency < 1 || *concurrency > 128 {
		fmt.Fprintln(os.Stderr, "valid URL, DEMO_TOKEN and bounded duration/warmup/concurrency required")
		os.Exit(1)
	}
	pre := run(*endpoint, token, "warmup", *warmup, *concurrency)
	if pre.Success == 0 {
		fmt.Fprintln(os.Stderr, "warmup produced no valid responses; check auth, gateway and telemetry")
		os.Exit(1)
	}
	output := run(*endpoint, token, *mode, *duration, *concurrency)
	encoder := json.NewEncoder(os.Stdout)
	encoder.SetIndent("", "  ")
	if err := encoder.Encode(output); err != nil {
		fmt.Fprintln(os.Stderr, "cannot write benchmark result")
		os.Exit(1)
	}
	if output.Success == 0 {
		os.Exit(1)
	}
}
