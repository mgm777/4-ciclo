package main

import (
	"context"
	"database/sql"
	"errors"
	"log"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/XSAM/otelsql"
	_ "github.com/jackc/pgx/v4/stdlib"
	"github.com/joho/godotenv"
	"go.opentelemetry.io/otel/attribute"
)

// App struct (para injeção de dependência)
type App struct {
	DB        *sql.DB
	MasterKey string
	Chaos     *Chaos
}

func main() {
	// Carrega o .env para desenvolvimento local. Em produção, isso não fará nada.
	_ = godotenv.Load()

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	shutdownTelemetry, err := setupTelemetry(ctx, "auth-service")
	if err != nil {
		log.Fatalf("Falha ao inicializar o OpenTelemetry: %v", err)
	}

	// --- Configuração ---
	port := os.Getenv("PORT")
	if port == "" {
		port = "8001" // Porta padrão
	}

	databaseURL := os.Getenv("DATABASE_URL")
	if databaseURL == "" {
		log.Fatal("DATABASE_URL deve ser definida")
	}

	masterKey := os.Getenv("MASTER_KEY")
	if masterKey == "" {
		log.Fatal("MASTER_KEY deve ser definida")
	}

	// --- Conexão com o Banco ---
	db, err := connectDB(databaseURL)
	if err != nil {
		log.Fatalf("Não foi possível conectar ao banco de dados: %v", err)
	}
	defer db.Close()

	app := &App{
		DB:        db,
		MasterKey: masterKey,
		Chaos:     NewChaos(os.Getenv("CHAOS_ENABLED") == "true"),
	}

	// --- Rotas da API ---
	mux := http.NewServeMux()
	mux.HandleFunc("/health", app.healthHandler)

	// Endpoint público para validar uma chave
	mux.HandleFunc("/validate", app.validateKeyHandler)

	// Endpoints de "admin" para criar/gerenciar chaves
	// Eles são protegidos pelo middleware de autenticação
	mux.Handle("/admin/keys", app.masterKeyAuthMiddleware(http.HandlerFunc(app.createKeyHandler)))

	// Injeção de falha para a demonstração de incidente/self-healing.
	// Só existe quando CHAOS_ENABLED=true e exige a MASTER_KEY.
	mux.Handle("/admin/chaos", app.masterKeyAuthMiddleware(http.HandlerFunc(app.Chaos.Handler)))

	srv := &http.Server{
		Addr:              ":" + port,
		Handler:           instrumentHandler(app.Chaos.Middleware(mux), "auth-service"),
		ReadHeaderTimeout: 5 * time.Second,
	}

	go func() {
		log.Printf("Serviço de Autenticação (Go) rodando na porta %s", port)
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

// connectDB inicializa e testa a conexão com o PostgreSQL
func connectDB(databaseURL string) (*sql.DB, error) {
	// otelsql cria um span CLIENT por query: o banco aparece no trace e no
	// Service Map do New Relic como dependência do auth-service.
	db, err := otelsql.Open("pgx", databaseURL,
		otelsql.WithAttributes(attribute.String("db.system.name", "postgresql")),
		otelsql.WithSpanOptions(otelsql.SpanOptions{OmitConnResetSession: true, OmitRows: true}),
	)
	if err != nil {
		return nil, err
	}

	if err = db.Ping(); err != nil {
		return nil, err
	}

	log.Println("Conectado ao PostgreSQL com sucesso!")
	return db, nil
}
