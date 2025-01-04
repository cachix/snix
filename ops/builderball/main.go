package main

import (
	"flag"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"time"

	"tvl.fyi/ops/builderball/config"
	"tvl.fyi/ops/builderball/proxy"
)

func printStats() {
	hits, misses := proxy.GetStats()
	if hits > 0 || misses > 0 {
		slog.Info("served cache requests", "hits", hits, "misses", misses)
	}
}

func main() {
	flag.Parse()
	slog.Info("launching builderball proxy", "host", *config.Host, "port", *config.Port)

	logConfig := slog.HandlerOptions{
		Level: slog.LevelInfo,
	}

	if *config.Debug {
		logConfig.Level = slog.LevelDebug
	}

	if *config.JSON {
		logConfig.AddSource = true
		slog.SetDefault(slog.New(slog.NewJSONHandler(os.Stderr, &logConfig)))
	} else {
		slog.SetDefault(slog.New(slog.NewTextHandler(os.Stderr, &logConfig)))
	}

	slog.Debug("debug logging enabled") // prints only then, of course.

	if len(config.Caches) > 0 {
		slog.Info("static binary caches configured", "caches", config.Caches)
	}

	if *config.Tailscale {
		slog.Info("tailscale discovery is enabled", "tag", *config.TSTag)
	} else if len(config.Caches) == 0 {
		slog.Error("no static binary caches configured, and tailscale discovery is disabled")
		os.Exit(1)
	}

	http.HandleFunc("GET /nix-cache-info", func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprintf(w, `StoreDir: /nix/store
WantMassQuery: 1
Priority: %d
`, *config.Priority)
	})

	http.HandleFunc("GET /", proxy.Handler)

	go func() {
		for {
			printStats()
			time.Sleep(time.Duration(*config.Ticker) * time.Second)
		}
	}()

	err := http.ListenAndServe(fmt.Sprintf("%s:%d", *config.Host, *config.Port), nil)
	if err != nil {
		slog.Error("HTTP server failed", "error", err.Error())
		os.Exit(1)
	}
}
