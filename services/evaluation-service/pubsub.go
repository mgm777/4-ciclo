package main

import (
	"encoding/json"
	"log"
	"time"

	"cloud.google.com/go/pubsub/v2"
)

type EvaluationEvent struct {
	UserID    string    `json:"user_id"`
	FlagName  string    `json:"flag_name"`
	Result    bool      `json:"result"`
	Timestamp time.Time `json:"timestamp"`
}

func (a *App) sendEvaluationEvent(userID, flagName string, result bool) {
	if a.PubsubPublisher == nil {
		log.Printf("[PUBSUB_DISABLED] Evento: User '%s', Flag '%s', Result '%t'", userID, flagName, result)
		return
	}

	event := EvaluationEvent{
		UserID:    userID,
		FlagName:  flagName,
		Result:    result,
		Timestamp: time.Now().UTC(),
	}

	body, err := json.Marshal(event)
	if err != nil {
		log.Printf("Erro ao serializar evento Pub/Sub: %v", err)
		return
	}

	publishResult := a.PubsubPublisher.Publish(ctx, &pubsub.Message{Data: body})
	if _, err := publishResult.Get(ctx); err != nil {
		log.Printf("Erro ao publicar mensagem no Pub/Sub: %v", err)
	} else {
		log.Printf("Evento de avaliação publicado no Pub/Sub (Flag: %s)", flagName)
	}
}
