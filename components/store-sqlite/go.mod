module store-sqlite

go 1.26.0

require (
	github.com/asg017/sqlite-vec-go-bindings v0.1.7-alpha.2
	github.com/mattn/go-sqlite3 v1.14.24
	github.com/pressly/goose/v3 v3.28.0
	niffler.dev/sdk v0.0.0
)

require (
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
