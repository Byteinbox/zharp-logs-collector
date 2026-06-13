FROM golang:1.26-alpine AS builder
WORKDIR /src
COPY . .
RUN CGO_ENABLED=0 GOOS=linux go build -C ./dist \
    -ldflags="-s -w" \
    -o /zharp-collector \
    .

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=builder /zharp-collector /zharp-collector

# Health check (HTTP)
EXPOSE 13133
# zPages debug UI
EXPOSE 55679
# OTLP gRPC
EXPOSE 4317
# OTLP HTTP
EXPOSE 4318

ENTRYPOINT ["/zharp-collector"]
CMD ["--config", "/etc/zharp-collector/config.yaml"]
