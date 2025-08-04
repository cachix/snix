package main

import (
	"bytes"
	"context"
	"encoding/json"
	"flag"
	"log"
	"log/slog"
	"net"
	"net/http"
	"os"
	"os/signal"
	"strings"
	"text/template"

	"github.com/coreos/go-systemd/v22/activation"
	sloghttp "github.com/samber/slog-http"
	"golang.org/x/sync/errgroup"

	gerritStreams "github.com/andygrunwald/go-gerrit/streams"
)

var logger *slog.Logger
var tmplStr = `{{- if eq .Type "patchset-created" -}}
{{- if (and (eq .PatchSet.Number 1) (eq .Change.Wip false) ) -}}
#snix CL/{{.Change.Number}} proposed by {{.Change.Owner.Username}} - {{.Change.Subject}} - {{.Change.URL}}
{{- end -}}
{{- else if eq .Type "change-merged" -}}
{{- if eq .Submitter.Username "clbot" -}}
#snix CL/{{.Change.Number}} by {{.Change.Owner.Username}} autosubmitted - {{.Change.Subject}} - {{.Change.URL}}
{{- else -}}
#snix CL/{{.Change.Number}} applied by {{.Change.Owner.Username}} - {{.Change.Subject}} - {{.Change.URL}}
{{- end -}}
{{- else if eq .Type "wip-state-changed" -}}
{{- if eq .Change.Wip false -}}
#snix CL/{{.Change.Number}} undrafted by {{.Changer.Username}} - {{.Change.Subject}} - {{.Change.URL}}
{{- end -}}
{{- end -}}`
var tmpl = template.Must(template.New("msg").Parse(tmplStr))

var irccatUrl = flag.String("irccat-url", "", "Full URL pointing to the irccat /send endpoint.")

// Receives HTTP requests from Gerrit, with the request payload following the
// same structure as the `gerrit stream-events` command.
func handler(w http.ResponseWriter, r *http.Request) {
	var body bytes.Buffer
	if _, err := body.ReadFrom(r.Body); err != nil {
		logger.WarnContext(r.Context(), "failed to read body", slog.Any("error", err))
		return
	}
	logger.InfoContext(r.Context(), "received event", slog.Any("body", body.Bytes()))

	var event gerritStreams.Event
	if err := json.Unmarshal(body.Bytes(), &event); err != nil {
		logger.WarnContext(r.Context(), "failed to parse body", slog.Any("error", err))
		return
	}

	logger.InfoContext(r.Context(), "received event", slog.Any("event", event))

	// render the template into a buffer.
	var msg bytes.Buffer
	if err := tmpl.Execute(&msg, event); err != nil {
		logger.WarnContext(r.Context(), "failed to execute template with data", slog.Any("error", err))
		return
	}

	// trim whitespace, just in case.
	msgStr := strings.TrimSpace(msg.String())

	// if the template did return data, send to irccat
	if len(msgStr) > 0 {
		// content-type doesn't matter, we don't run irccat in strict mode
		_, err := http.Post(*irccatUrl, "application/octet-stream", bytes.NewReader([]byte(msgStr)))
		if err != nil {
			logger.WarnContext(r.Context(), "failed to send data to irccat", slog.Any("msg", msgStr), slog.Any("error", err))
			return
		}
	}
}

func main() {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt)
	defer stop()

	logger = slog.New(slog.NewTextHandler(os.Stderr, nil))

	listeners, err := activation.Listeners()
	if err != nil {
		log.Fatalf("unable to get listeners: %s", err)
	}

	if len(listeners) == 0 {
		log.Fatal("no listeners specified, did you configure socket activation correctly?")
	}

	flag.Parse()
	if *irccatUrl == "" {
		log.Fatal("no -irccat-url specified")
	}

	g, ctx := errgroup.WithContext(ctx)
	server := &http.Server{
		Handler: sloghttp.New(logger)(http.HandlerFunc(handler)),
		BaseContext: func(l net.Listener) context.Context {
			return ctx
		},
	}

	for _, listener := range listeners {
		g.Go(func() error {
			return server.Serve(listener)
		})
	}

	if err := g.Wait(); err != nil {
		panic(err)
	}

	<-ctx.Done()
}
