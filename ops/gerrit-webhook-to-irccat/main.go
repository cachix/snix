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

	"github.com/andygrunwald/go-gerrit"
)

// TODO:
// {"submitter":{"name":"Florian Klink","email":"flokli@flokli.de","username":"flokli"},"refUpdate":{"oldRev":"6097f070f549df94339a2b90b2e8670195c99ec3","newRev":"b339defea41b329aa33d80dcaa22623daeb040b6","refName":"refs/changes/25/30525/meta","project":"snix"},"type":"ref-updated","eventCreatedOn":1747336314}
// {"changer":{"name":"Florian Klink","email":"flokli@flokli.de","username":"flokli"},"patchSet":{"number":1,"revision":"ede307a009aa0b1eb62e9f18b7bf1f26e9fc98a9","parents":["9f8fb55318f2bafb37e4587fa4b6c793b2b540c0"],"ref":"refs/changes/25/30525/1","uploader":{"name":"Florian Klink","email":"flokli@flokli.de","username":"flokli"},"createdOn":1747335735,"author":{"name":"Florian Klink","email":"flokli@flokli.de","username":"flokli"},"kind":"REWORK","sizeInsertions":11,"sizeDeletions":1545},"change":{"project":"snix","branch":"canon","id":"If8faecdd018b45dd087b7332fe3d3a8280947358","number":30525,"subject":"fix(ops): drop clbot","owner":{"name":"Florian Klink","email":"flokli@flokli.de","username":"flokli"},"url":"https://cl.snix.dev/c/snix/+/30525","commitMessage":"fix(ops): drop clbot\n\nThis removes the old clbot, which kept an SSH connection to gerrit open.\n\nChange-Id: If8faecdd018b45dd087b7332fe3d3a8280947358\n","createdOn":1747335735,"status":"NEW"},"project":"snix","refName":"refs/heads/canon","changeKey":{"id":"If8faecdd018b45dd087b7332fe3d3a8280947358"},"type":"wip-state-changed","eventCreatedOn":1747336314}

var logger *slog.Logger
var tmplStr = `{{- if eq .Type "patchset-created" -}}
{{- if (and (eq .PatchSet.Number "1") (eq .Change.WorkInProgress false) ) -}}
#snix CL/{{.Change.Number}} proposed by {{.Change.Owner.Username}} - {{.Change.Subject}} - {{.Change.URL}}
{{- end -}}
{{- else if eq .Type "change-merged" -}}
{{- if eq .Submitter.Username "clbot" -}}
#snix CL/{{.Change.Number}} by {{.Change.Owner.Username}} autosubmitted - {{.Change.Subject}} - {{.Change.URL}}
{{- else -}}
#snix CL/{{.Change.Number}} applied by {{.Change.Owner.Username}} - {{.Change.Subject}} - {{.Change.URL}}
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

	var eventInfo gerrit.EventInfo
	if err := json.Unmarshal(body.Bytes(), &eventInfo); err != nil {
		logger.WarnContext(r.Context(), "failed to parse body", slog.Any("error", err))
		return
	}

	logger.InfoContext(r.Context(), "received event", slog.Any("event", eventInfo))

	// render the template into a buffer.
	var msg bytes.Buffer
	if err := tmpl.Execute(&msg, eventInfo); err != nil {
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
