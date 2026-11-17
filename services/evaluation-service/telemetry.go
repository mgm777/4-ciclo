package main

import (
	"context"
	"errors"
	"log"
	"net/http"
	"os"
	"time"

	"go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp"
	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/exporters/otlp/otlpmetric/otlpmetrichttp"
	"go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracehttp"
	"go.opentelemetry.io/otel/propagation"
	sdkmetric "go.opentelemetry.io/otel/sdk/metric"
	"go.opentelemetry.io/otel/sdk/resource"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
	"go.opentelemetry.io/otel/trace"
)

// setupTelemetry configura traces e métricas OpenTelemetry exportando via
// OTLP/HTTP para o OTel Collector. Toda a configuração vem das variáveis
// padrão do OTel (OTEL_EXPORTER_OTLP_ENDPOINT, OTEL_SERVICE_NAME,
// OTEL_RESOURCE_ATTRIBUTES), então o mesmo binário roda local e no cluster.
// Sem OTEL_EXPORTER_OTLP_ENDPOINT a telemetria fica desligada (no-op).
func setupTelemetry(ctx context.Context, defaultServiceName string) (func(context.Context) error, error) {
	// O propagador W3C é configurado sempre, para repassar o contexto adiante
	// mesmo quando este serviço não exporta nada.
	otel.SetTextMapPropagator(propagation.NewCompositeTextMapPropagator(
		propagation.TraceContext{}, propagation.Baggage{},
	))

	if os.Getenv("OTEL_EXPORTER_OTLP_ENDPOINT") == "" {
		log.Println("OTEL_EXPORTER_OTLP_ENDPOINT não definido: telemetria desabilitada.")
		return func(context.Context) error { return nil }, nil
	}

	// Detectores aplicados em ordem; os últimos têm precedência, então
	// OTEL_SERVICE_NAME / OTEL_RESOURCE_ATTRIBUTES sobrescrevem o padrão.
	res, err := resource.New(ctx,
		resource.WithAttributes(attribute.String("service.name", defaultServiceName)),
		resource.WithTelemetrySDK(),
		resource.WithFromEnv(),
	)
	if err != nil {
		return nil, err
	}

	traceExp, err := otlptracehttp.New(ctx)
	if err != nil {
		return nil, err
	}
	tp := sdktrace.NewTracerProvider(
		sdktrace.WithBatcher(traceExp),
		sdktrace.WithResource(res),
	)
	otel.SetTracerProvider(tp)

	metricExp, err := otlpmetrichttp.New(ctx)
	if err != nil {
		return nil, err
	}
	mp := sdkmetric.NewMeterProvider(
		sdkmetric.WithReader(sdkmetric.NewPeriodicReader(metricExp, sdkmetric.WithInterval(15*time.Second))),
		sdkmetric.WithResource(res),
	)
	otel.SetMeterProvider(mp)

	log.Printf("OpenTelemetry habilitado (endpoint: %s)", os.Getenv("OTEL_EXPORTER_OTLP_ENDPOINT"))
	return func(ctx context.Context) error {
		return errors.Join(tp.Shutdown(ctx), mp.Shutdown(ctx))
	}, nil
}

// instrumentHandler envolve o mux com o otelhttp: cria um span SERVER por
// requisição e emite a métrica http.server.request.duration (com o status
// code), que alimenta o dashboard e o alerta de taxa de erro 5xx.
// O /health fica de fora para não poluir traces e métricas com as probes.
func instrumentHandler(h http.Handler, operation string) http.Handler {
	return otelhttp.NewHandler(h, operation,
		otelhttp.WithFilter(func(r *http.Request) bool { return r.URL.Path != "/health" }),
		otelhttp.WithSpanNameFormatter(func(_ string, r *http.Request) string {
			return r.Method + " " + r.URL.Path
		}),
	)
}

// logf registra uma linha de log com o trace_id/span_id do contexto, para
// correlacionar log (Loki / New Relic) com o trace distribuído.
func logf(ctx context.Context, format string, args ...any) {
	if sc := trace.SpanContextFromContext(ctx); sc.IsValid() {
		format = "trace_id=" + sc.TraceID().String() + " span_id=" + sc.SpanID().String() + " " + format
	}
	log.Printf(format, args...)
}
