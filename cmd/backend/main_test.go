package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func fixture(now time.Time) (node, metrics) {
	var n node
	n.Status.Capacity = map[string]string{"cpu": "4"}
	n.Metadata.Labels = map[string]string{"node.kubernetes.io/instance-type": "test-sku"}
	return n, metrics{Timestamp: now, Window: "15s", Usage: map[string]string{"cpu": "1000000000n"}}
}

func TestNodeCapacityNotAllocatable(t *testing.T) {
	now := time.Now()
	n, m := fixture(now)
	for _, q := range []string{"1000000000n", "1000000u", "1000m", "1"} {
		m.Usage["cpu"] = q
		s, err := cpuSample(n, m, now)
		if err != nil || *s.CPU != 0.25 {
			t.Fatalf("quantity %s: sample %+v error %v", q, s, err)
		}
	}
}

func TestInvalidTelemetry(t *testing.T) {
	now := time.Now()
	for _, change := range []func(*node, *metrics){
		func(n *node, m *metrics) { m.Timestamp = now.Add(-61 * time.Second) },
		func(n *node, m *metrics) { m.Timestamp = now.Add(6 * time.Second) },
		func(n *node, m *metrics) { m.Window = "0s" },
		func(n *node, m *metrics) { m.Window = "bogus" },
		func(n *node, m *metrics) { n.Status.Capacity["cpu"] = "0" },
		func(n *node, m *metrics) { m.Usage["cpu"] = "NaN" },
		func(n *node, m *metrics) { m.Usage["cpu"] = "5" },
		func(n *node, m *metrics) { m.Usage["cpu"] = "0" },
		func(n *node, m *metrics) { delete(n.Metadata.Labels, "node.kubernetes.io/instance-type") },
	} {
		n, m := fixture(now)
		change(&n, &m)
		s, err := cpuSample(n, m, now)
		if err == nil || s.CPU != nil {
			t.Fatalf("invalid telemetry accepted: %+v %v", s, err)
		}
	}
}

func TestMeasuredRateWarmupExpirationAndErrors(t *testing.T) {
	now := time.Now()
	n, m := fixture(now)
	v, _ := cpuSample(n, m, now)
	s := &state{start: now.Add(-10 * time.Second), current: v}
	s.record(now.Add(-5*time.Second), false)
	_, rps, _, header := s.report(now)
	if rps != 0.1 || header != "" {
		t.Fatal("warmup must measure elapsed time but omit ORCA")
	}
	s.start = now.Add(-time.Minute)
	s.record(now.Add(-31*time.Second), false)
	// Production events are chronological.
	s.events = []completion{{now.Add(-31 * time.Second), false}, {now.Add(-5 * time.Second), false}, {now, true}}
	_, rps, eps, header := s.report(now)
	if rps != 2.0/30 || eps != 1.0/30 || !strings.HasPrefix(header, "JSON ") {
		t.Fatalf("incorrect rolling rate: %v %v %q", rps, eps, header)
	}
	var orca map[string]float64
	if err := json.Unmarshal([]byte(strings.TrimPrefix(header, "JSON ")), &orca); err != nil || orca["cpuUtilization"] != 0.25 {
		t.Fatal("invalid ORCA JSON")
	}
	_, rps, _, header = s.report(now.Add(61 * time.Second))
	if rps != 0 || header != "" {
		t.Fatal("idle/stale reports must not emit fabricated metrics")
	}
}

func TestHTTPAuthenticationAndProbeExcludedFromRate(t *testing.T) {
	now := time.Now()
	n, m := fixture(now)
	v, _ := cpuSample(n, m, now)
	s := &state{start: now.Add(-time.Minute), current: v}
	h := handler(s, strings.Repeat("x", 32), "node", "pod")
	for _, path := range []string{"/healthz", "/work"} {
		w := httptest.NewRecorder()
		h.ServeHTTP(w, httptest.NewRequest("GET", path, nil))
		if len(s.events) != 0 {
			t.Fatal("unauthorized requests or probes counted")
		}
	}
	w := httptest.NewRecorder()
	r := httptest.NewRequest("GET", "/work", nil)
	r.Header.Set("Authorization", "Bearer "+strings.Repeat("x", 32))
	h.ServeHTTP(w, r)
	if w.Code != http.StatusOK || w.Header().Get("endpoint-load-metrics") == "" || len(s.events) != 1 {
		t.Fatal("authorized computation must report measured completed request")
	}
}

func TestKubeClientRotationAndErrors(t *testing.T) {
	path := filepath.Join(t.TempDir(), "token")
	if err := os.WriteFile(path, []byte("first"), 0600); err != nil {
		t.Fatal(err)
	}
	expected := "first"
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "Bearer "+expected {
			t.Error("projected token was not reread")
		}
		if r.URL.Path == "/failure" {
			w.WriteHeader(403)
			return
		}
		w.Write([]byte(`{"usage":{"cpu":"1"}}`))
	}))
	defer server.Close()
	k := kubeClient{server.URL, path, server.Client()}
	var m metrics
	if err := k.get("/ok", &m); err != nil {
		t.Fatal(err)
	}
	expected = "rotated"
	if err := os.WriteFile(path, []byte(expected), 0600); err != nil {
		t.Fatal(err)
	}
	if err := k.get("/ok", &m); err != nil {
		t.Fatal(err)
	}
	if err := k.get("/failure", &m); err == nil {
		t.Fatal("API failure must be surfaced")
	}
}
