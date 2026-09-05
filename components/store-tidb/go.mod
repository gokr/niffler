module store-tidb

go 1.26.0

require (
	github.com/go-sql-driver/mysql v1.10.0
	github.com/pressly/goose/v3 v3.28.0
	niffler.dev/sdk v0.0.0
)

require (
	filippo.io/edwards25519 v1.2.0 // indirect
	github.com/klauspost/compress v1.19.2 // indirect
	github.com/mfridman/interpolate v0.0.2 // indirect
	github.com/nats-io/nats.go v1.41.1 // indirect
	github.com/nats-io/nkeys v0.4.9 // indirect
	github.com/nats-io/nuid v1.0.1 // indirect
	github.com/sethvargo/go-retry v0.4.0 // indirect
	go.uber.org/multierr v1.11.0 // indirect
	golang.org/x/crypto v0.55.0 // indirect
	golang.org/x/sync v0.22.0 // indirect
	golang.org/x/sys v0.47.0 // indirect
)

replace niffler.dev/sdk => ../../sdk/go
