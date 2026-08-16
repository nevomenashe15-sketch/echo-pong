package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
)

// withSecret sets the package-level secret for the duration of a test and restores it after.
func withSecret(t *testing.T, value string) {
	t.Helper()
	prev := secret
	secret = value
	t.Cleanup(func() { secret = prev })
}

func TestHealthHandler(t *testing.T) {
	req := httptest.NewRequest(http.MethodGet, "/health", nil)
	w := httptest.NewRecorder()

	healthHandler(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("expected status %d, got %d", http.StatusOK, w.Code)
	}

	var body map[string]interface{}
	if err := json.Unmarshal(w.Body.Bytes(), &body); err != nil {
		t.Fatalf("failed to decode health response: %v", err)
	}
	if body["status"] != "healthy" {
		t.Fatalf("expected status \"healthy\", got %v", body["status"])
	}
}

func TestRootHandler(t *testing.T) {
	req := httptest.NewRequest(http.MethodGet, "/", nil)
	w := httptest.NewRecorder()

	rootHandler(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("expected status %d, got %d", http.StatusOK, w.Code)
	}
	if ct := w.Header().Get("Content-Type"); ct != "text/html; charset=utf-8" {
		t.Fatalf("expected html content-type, got %q", ct)
	}
}

func TestPingHandler(t *testing.T) {
	req := httptest.NewRequest(http.MethodGet, "/ping", nil)
	w := httptest.NewRecorder()

	pingHandler(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("expected status %d, got %d", http.StatusOK, w.Code)
	}
	var body Response
	if err := json.Unmarshal(w.Body.Bytes(), &body); err != nil {
		t.Fatalf("failed to decode ping response: %v", err)
	}
	if body.Message != "pong" {
		t.Fatalf("expected message \"pong\", got %q", body.Message)
	}
}

func TestPongHandler(t *testing.T) {
	req := httptest.NewRequest(http.MethodGet, "/pong", nil)
	w := httptest.NewRecorder()

	pongHandler(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("expected status %d, got %d", http.StatusOK, w.Code)
	}
	var body Response
	if err := json.Unmarshal(w.Body.Bytes(), &body); err != nil {
		t.Fatalf("failed to decode pong response: %v", err)
	}
	if body.Message != "ping" {
		t.Fatalf("expected message \"ping\", got %q", body.Message)
	}
}

func TestAuthMiddleware(t *testing.T) {
	withSecret(t, "s3cr3t-token")

	protected := authMiddleware(pingHandler)

	cases := []struct {
		name       string
		authHeader string
		wantStatus int
	}{
		{"missing header", "", http.StatusUnauthorized},
		{"wrong raw token", "wrong-token", http.StatusUnauthorized},
		{"wrong bearer token", "Bearer wrong-token", http.StatusUnauthorized},
		{"correct raw token", "s3cr3t-token", http.StatusOK},
		{"correct bearer token", "Bearer s3cr3t-token", http.StatusOK},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			req := httptest.NewRequest(http.MethodGet, "/ping", nil)
			if tc.authHeader != "" {
				req.Header.Set("Authorization", tc.authHeader)
			}
			w := httptest.NewRecorder()

			protected(w, req)

			if w.Code != tc.wantStatus {
				t.Fatalf("expected status %d, got %d", tc.wantStatus, w.Code)
			}
		})
	}
}

func TestValidatePassword(t *testing.T) {
	withSecret(t, "s3cr3t-token")

	if !validatePassword("s3cr3t-token") {
		t.Fatal("expected correct password to validate")
	}
	if validatePassword("wrong") {
		t.Fatal("expected incorrect password to not validate")
	}
	if validatePassword("") {
		t.Fatal("expected empty password to not validate")
	}
}
