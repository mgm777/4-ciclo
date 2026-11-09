FROM golang:1.25-alpine AS builder

WORKDIR /src

COPY go.mod go.sum ./
RUN go mod download

COPY . .

RUN CGO_ENABLED=0 GOOS=linux go build -o /out/evaluation-service .

FROM alpine:3.21

RUN apk add --no-cache ca-certificates && \
    adduser -D -u 1000 appuser
USER appuser

WORKDIR /app
COPY --from=builder /out/evaluation-service .

EXPOSE 8004
ENTRYPOINT ["./evaluation-service"]
