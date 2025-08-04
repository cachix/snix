module snix.dev/ops/gerrit-webhook-to-irccat

go 1.24.2

require (
	github.com/andygrunwald/go-gerrit v1.0.0
	github.com/coreos/go-systemd/v22 v22.5.0
	github.com/samber/slog-http v1.6.0
	github.com/stretchr/testify v1.10.0
	golang.org/x/sync v0.13.0
)

require (
	github.com/davecgh/go-spew v1.1.1 // indirect
	github.com/google/uuid v1.6.0 // indirect
	github.com/pmezard/go-difflib v1.0.0 // indirect
	go.opentelemetry.io/otel v1.29.0 // indirect
	go.opentelemetry.io/otel/trace v1.29.0 // indirect
	gopkg.in/yaml.v3 v3.0.1 // indirect
)

// Use the different data types sent in streams
// https://github.com/andygrunwald/go-gerrit/pull/189
replace github.com/andygrunwald/go-gerrit => github.com/flokli/go-gerrit v0.0.0-20250728210913-fadc61de9b89
