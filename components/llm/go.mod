module llm

go 1.24

require (
	github.com/sashabaranov/go-openai v1.42.0
	niffler.dev/sdk v0.0.0
)

require (
	github.com/klauspost/compress v1.18.0 // indirect
	github.com/nats-io/nats.go v1.41.1 // indirect
	github.com/nats-io/nkeys v0.4.9 // indirect
	github.com/nats-io/nuid v1.0.1 // indirect
	golang.org/x/crypto v0.31.0 // indirect
	golang.org/x/sys v0.28.0 // indirect
)

replace niffler.dev/sdk => ../../sdk/go
