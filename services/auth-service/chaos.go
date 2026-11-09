package main

import (
	"encoding/json"
	"log"
	"net/http"
	"strconv"
	"strings"
	"sync/atomic"
)

// Chaos implementa uma injeção de falha controlada, usada na demonstração do
// incidente: reproduz o cenário do enunciado, em que o serviço "falha
// silenciosamente" — o /health continua respondendo 200 (as probes do
// Kubernetes não percebem nada), mas as requisições de negócio retornam 500.
//
// O estado fica só em memória, no pod. Por isso o `kubectl rollout restart`
// executado pelo self-healer realmente "cura" o serviço: os pods novos sobem
// sem a falha.
//
// A falha é determinística (a cada 100 requisições, as N primeiras falham),
// o que evita depender de math/rand e deixa a taxa de erro previsível.
type Chaos struct {
	enabled    bool
	errorRate  atomic.Int64 // percentual de 0 a 100
	reqCounter atomic.Uint64
}

func NewChaos(enabled bool) *Chaos {
	if enabled {
		log.Println("[CHAOS] Injeção de falha disponível em /admin/chaos (CHAOS_ENABLED=true).")
	}
	return &Chaos{enabled: enabled}
}

// Middleware devolve 500 para a fração configurada das requisições.
// /health e /admin/* nunca são afetados.
func (c *Chaos) Middleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		rate := c.errorRate.Load()
		if rate > 0 && r.URL.Path != "/health" && !strings.HasPrefix(r.URL.Path, "/admin/") {
			n := c.reqCounter.Add(1)
			if int64(n%100) < rate {
				logf(r.Context(), "[CHAOS] Falha injetada em %s %s (error_rate=%d%%)", r.Method, r.URL.Path, rate)
				http.Error(w, `{"error": "falha interna (chaos)"}`, http.StatusInternalServerError)
				return
			}
		}
		next.ServeHTTP(w, r)
	})
}

// Handler: GET consulta, POST ?error_rate=<0-100> liga, DELETE desliga.
func (c *Chaos) Handler(w http.ResponseWriter, r *http.Request) {
	if !c.enabled {
		http.Error(w, "Injeção de falha desabilitada (CHAOS_ENABLED != true)", http.StatusNotFound)
		return
	}

	switch r.Method {
	case http.MethodGet:
	case http.MethodPost:
		rate, err := strconv.Atoi(r.URL.Query().Get("error_rate"))
		if err != nil || rate < 0 || rate > 100 {
			http.Error(w, "error_rate deve ser um inteiro entre 0 e 100", http.StatusBadRequest)
			return
		}
		c.errorRate.Store(int64(rate))
		log.Printf("[CHAOS] Injeção de falha LIGADA: error_rate=%d%%", rate)
	case http.MethodDelete:
		c.errorRate.Store(0)
		log.Println("[CHAOS] Injeção de falha DESLIGADA")
	default:
		http.Error(w, "Método não permitido", http.StatusMethodNotAllowed)
		return
	}

	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(map[string]int64{"error_rate": c.errorRate.Load()})
}
