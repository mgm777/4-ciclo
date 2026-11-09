package main

import (
	"context"
	"errors"
	"log"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"cloud.google.com/go/pubsub/v2"
	"github.com/go-redis/redis/v8"
	"github.com/joho/godotenv"
	"go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp"
)

type App struct {
	RedisClient         *redis.Client
	PubsubPublisher     *pubsub.Publisher
	PubsubTopicID       string
	HttpClient          *http.Client
	FlagServiceURL      string
	TargetingServiceURL string
}

func main() {
	_ = godotenv.Load()

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	shutdownTelemetry, err := setupTelemetry(ctx, "evaluation-service")
	if err != nil {
		log.Fatalf("Falha ao inicializar o OpenTelemetry: %v", err)
	}

	port := os.Getenv("PORT")
	if port == "" {
		port = "8004"
	}

	redisURL := os.Getenv("REDIS_URL")
	if redisURL == "" {
		log.Fatal("REDIS_URL deve ser definida (ex: redis://localhost:6379)")
	}

	flagSvcURL := os.Getenv("FLAG_SERVICE_URL")
	if flagSvcURL == "" {
		log.Fatal("FLAG_SERVICE_URL deve ser definida")
	}

	targetingSvcURL := os.Getenv("TARGETING_SERVICE_URL")
	if targetingSvcURL == "" {
		log.Fatal("TARGETING_SERVICE_URL deve ser definida")
	}

	gcpProjectID := os.Getenv("GCP_PROJECT_ID")
	pubsubTopicID := os.Getenv("PUBSUB_TOPIC_ID")
	if gcpProjectID == "" || pubsubTopicID == "" {
		log.Println("Atenção: GCP_PROJECT_ID/PUBSUB_TOPIC_ID não definidos. Eventos não serão publicados.")
	}

	opt, err := redis.ParseURL(redisURL)
	if err != nil {
		log.Fatalf("Não foi possível parsear a URL do Redis: %v", err)
	}
	rdb := redis.NewClient(opt)
	if _, err := rdb.Ping(ctx).Result(); err != nil {
		log.Fatalf("Não foi possível conectar ao Redis: %v", err)
	}
	log.Println("Conectado ao Redis com sucesso!")

	var publisher *pubsub.Publisher
	if gcpProjectID != "" && pubsubTopicID != "" {
		client, err := pubsub.NewClient(ctx, gcpProjectID)
		if err != nil {
			log.Fatalf("Não foi possível criar o client do Pub/Sub: %v", err)
		}
		publisher = client.Publisher(pubsubTopicID)
		defer publisher.Stop()
		log.Println("Publisher do Pub/Sub inicializado com sucesso.")
	}

	// O transport do otelhttp cria um span CLIENT por chamada e injeta o
	// header W3C traceparent — é isso que liga o trace do evaluation-service
	// aos do flag-service e do targeting-service.
	httpClient := &http.Client{
		Timeout:   5 * time.Second,
		Transport: otelhttp.NewTransport(http.DefaultTransport),
	}

	app := &App{
		RedisClient:         rdb,
		PubsubPublisher:     publisher,
		PubsubTopicID:       pubsubTopicID,
		HttpClient:          httpClient,
		FlagServiceURL:      flagSvcURL,
		TargetingServiceURL: targetingSvcURL,
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/health", app.healthHandler)
	mux.HandleFunc("/evaluate", app.evaluationHandler)

	srv := &http.Server{
		Addr:              ":" + port,
		Handler:           instrumentHandler(mux, "evaluation-service"),
		ReadHeaderTimeout: 5 * time.Second,
	}

	go func() {
		log.Printf("Serviço de Avaliação (Go) rodando na porta %s", port)
		if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			log.Fatal(err)
		}
	}()

	<-ctx.Done()
	log.Println("Sinal de término recebido, encerrando...")
	shutdownCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	_ = srv.Shutdown(shutdownCtx)
	if err := shutdownTelemetry(shutdownCtx); err != nil {
		log.Printf("Erro ao encerrar o OpenTelemetry: %v", err)
	}
}
