# syntax=docker/dockerfile:1.6

FROM golang:1.22-bullseye AS builder
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 \
    go build -trimpath -ldflags="-s -w" -o /out/matcher ./cmd/matcher

FROM gcr.io/distroless/base-debian12
WORKDIR /app
COPY --from=builder /out/matcher /app/matcher
ENTRYPOINT ["/app/matcher"]

