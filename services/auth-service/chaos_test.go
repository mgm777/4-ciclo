package main

import (
	"net/http"
	"net/http/httptest"
	"testing"
)

func okHandler() http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) { w.WriteHeader(http.StatusOK) })
}

func countErrors(h http.Handler, path string, n int) int {
	errs := 0
	for i := 0; i < n; i++ {
		rec := httptest.NewRecorder()
		h.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, path, nil))
		if rec.Code == http.StatusInternalServerError {
			errs++
		}
	}
	return errs
}

func TestChaosDisabledByDefaultDoesNotFail(t *testing.T) {
	c := NewChaos(true)
	if got := countErrors(c.Middleware(okHandler()), "/validate", 100); got != 0 {
		t.Fatalf("esperava 0 erros sem error_rate, veio %d", got)
	}
}

func TestChaosInjectsConfiguredErrorRate(t *testing.T) {
	c := NewChaos(true)
	c.errorRate.Store(30)
	if got := countErrors(c.Middleware(okHandler()), "/validate", 100); got != 30 {
		t.Fatalf("esperava 30 erros em 100 requisições, veio %d", got)
	}
}

func TestChaosNeverAffectsHealth(t *testing.T) {
	c := NewChaos(true)
	c.errorRate.Store(100)
	if got := countErrors(c.Middleware(okHandler()), "/health", 50); got != 0 {
		t.Fatalf("/health não pode falhar com chaos ligado, veio %d erros", got)
	}
}

func TestChaosHandlerRequiresEnabledFlag(t *testing.T) {
	c := NewChaos(false)
	rec := httptest.NewRecorder()
	c.Handler(rec, httptest.NewRequest(http.MethodPost, "/admin/chaos?error_rate=50", nil))
	if rec.Code != http.StatusNotFound {
		t.Fatalf("esperava 404 com CHAOS_ENABLED=false, veio %d", rec.Code)
	}
	if c.errorRate.Load() != 0 {
		t.Fatal("error_rate não deveria mudar com o chaos desabilitado")
	}
}

func TestChaosHandlerSetsAndResetsRate(t *testing.T) {
	c := NewChaos(true)
	rec := httptest.NewRecorder()
	c.Handler(rec, httptest.NewRequest(http.MethodPost, "/admin/chaos?error_rate=50", nil))
	if rec.Code != http.StatusOK || c.errorRate.Load() != 50 {
		t.Fatalf("POST deveria ligar 50%%: code=%d rate=%d", rec.Code, c.errorRate.Load())
	}
	rec = httptest.NewRecorder()
	c.Handler(rec, httptest.NewRequest(http.MethodDelete, "/admin/chaos", nil))
	if c.errorRate.Load() != 0 {
		t.Fatalf("DELETE deveria desligar, rate=%d", c.errorRate.Load())
	}
}
