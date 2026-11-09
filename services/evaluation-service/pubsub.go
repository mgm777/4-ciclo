package main

import (
	"context"
	"encoding/json"
	"time"

	"cloud.google.com/go/pubsub/v2"
	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/codes"
	"go.opentelemetry.io/otel/propagation"
	"go.opentelemetry.io/otel/trace"
)

type EvaluationEvent struct {
	UserID    string    `json:"user_id"`
	FlagName  string    `json:"flag_name"`
	Result    bool      `json:"result"`
	Timestamp time.Time `json:"timestamp"`
}

// sendEvaluationEvent publica o evento no Pub/Sub dentro de um span PRODUCER
// e injeta o contexto W3C (traceparent) nos atributos da mensagem. O
// analytics-service extrai esse contexto ao consumir, então o trace segue
// evaluation-service -> Pub/Sub -> analytics-service sem quebrar.
func (a *App) sendEvaluationEvent(ctx context.Context, userID, flagName string, result bool) {
	if a.PubsubPublisher == nil {
		logf(ctx, "[PUBSUB_DISABLED] Evento: User '%s', Flag '%s', Result '%t'", userID, flagName, result)
		return
	}

	ctx, span := tracer.Start(ctx, "evaluation-events publish",
		trace.WithSpanKind(trace.SpanKindProducer),
		trace.WithAttributes(
			attribute.String("messaging.system", "gcp_pubsub"),
			attribute.String("messaging.destination.name", a.PubsubTopicID),
			attribute.String("messaging.operation.type", "send"),
			attribute.String("feature_flag.key", flagName),
		),
	)
	defer span.End()

	event := EvaluationEvent{
		UserID:    userID,
		FlagName:  flagName,
		Result:    result,
		Timestamp: time.Now().UTC(),
	}

	body, err := json.Marshal(event)
	if err != nil {
		span.RecordError(err)
		span.SetStatus(codes.Error, "falha ao serializar o evento")
		logf(ctx, "Erro ao serializar evento Pub/Sub: %v", err)
		return
	}

	attrs := map[string]string{}
	otel.GetTextMapPropagator().Inject(ctx, propagation.MapCarrier(attrs))

	publishResult := a.PubsubPublisher.Publish(ctx, &pubsub.Message{Data: body, Attributes: attrs})
	msgID, err := publishResult.Get(ctx)
	if err != nil {
		span.RecordError(err)
		span.SetStatus(codes.Error, "falha ao publicar no Pub/Sub")
		logf(ctx, "Erro ao publicar mensagem no Pub/Sub: %v", err)
		return
	}
	span.SetAttributes(attribute.String("messaging.message.id", msgID))
	logf(ctx, "Evento de avaliação publicado no Pub/Sub (Flag: %s)", flagName)
}
