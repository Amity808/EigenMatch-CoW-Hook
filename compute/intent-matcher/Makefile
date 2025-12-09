SHELL := /bin/bash
GOFILES := $(shell find . -name '*.go' -not -path "./vendor/*")

.PHONY: proto
proto:
	protoc -I api --go_out=./ --go-grpc_out=./ api/intent_matcher.proto

.PHONY: lint
lint:
	golangci-lint run ./...

.PHONY: test
test:
	go test ./...

.PHONY: docker
docker:
	docker build -f docker/Dockerfile -t eigenmatch/intent-matcher:dev .

