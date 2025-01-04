// Package proxy implements logic for proxying narinfo requests to upstream
// caches, and modifying their responses to let hosts fetch the required data
// directly from upstream.
package proxy

import (
	"context"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"strings"
	"sync/atomic"
	"time"

	"tvl.fyi/ops/builderball/config"
	"tvl.fyi/ops/builderball/discovery"
)

var hits atomic.Uint64
var misses atomic.Uint64

func GetStats() (uint64, uint64) {
	return hits.Swap(0), misses.Swap(0)
}

type narinfo struct {
	body string
	url  string
}

// fetchNarinfoWithAbsoluteURL contacts the cache at baseURL to see if it has
// the given NAR, and if so returns the narinfo with the URL pointing to the
// *absolute* address of the cache. Nix will follow the absolute URL for
// downloads.
func fetchNarinfoWithAbsoluteURL(ctx context.Context, r *http.Request, baseURL string) *narinfo {
	url := baseURL + r.URL.Path
	slog.Debug("querying upstream cache", "url", url)

	req, err := http.NewRequestWithContext(ctx, "GET", url, nil)

	if *config.CacheHost != "" {
		req.Header.Add("Host", *config.CacheHost)
	}

	if err != nil {
		slog.Warn("could not create cache lookup request", "cache", baseURL, "error", err.Error())
		return nil
	}

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		if errors.Is(err, context.Canceled) {
			slog.Debug("cancelled lookup to cache", "url", baseURL)
		} else if errors.Is(err, context.DeadlineExceeded) {
			slog.Info("cache timed out", "cache", baseURL)
		} else {
			slog.Warn("could not query cache", "cache", baseURL, "error", err.Error())
		}

		return nil
	}

	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		slog.Debug("upstream cache responded with non-OK status", "status", resp.Status)
		return nil
	}

	content, err := io.ReadAll(resp.Body)
	if err != nil {
		slog.Warn("could not read upstream response", "error", err.Error())
		return nil
	}

	result := new(narinfo)
	lines := strings.Split(string(content), "\n")
	for i, line := range lines {
		if strings.HasPrefix(line, "URL: ") {
			result.url = baseURL + "/" + strings.TrimPrefix(line, "URL: ")
			lines[i] = "URL: " + result.url
		}
	}

	result.body = strings.Join(lines, "\n")

	return result
}

func findInCaches(r *http.Request, caches []string) *narinfo {
	slog.Debug("querying caches", "caches", caches)
	ctx, cancel := context.WithTimeout(r.Context(), 1*time.Second)
	defer cancel()

	result := make(chan *narinfo, len(caches))

	for _, cacheURL := range caches {
		go func(baseURL string) {
			result <- fetchNarinfoWithAbsoluteURL(ctx, r, baseURL)
		}(cacheURL)
	}

	remaining := len(caches)
	for remaining > 0 {
		select {
		case <-ctx.Done():
			return nil
		case r := <-result:
			if r != nil {
				return r
			}

			remaining--
		}
	}

	return nil
}

func Handler(w http.ResponseWriter, r *http.Request) {
	// Only handle narinfo requests
	if !strings.HasSuffix(r.URL.Path, ".narinfo") {
		slog.Warn("received non-narinfo request", "path", r.URL.Path)
		http.NotFound(w, r)
		return
	}

	b := discovery.GetCaches()
	if len(b) == 0 {
		slog.Warn("no upstream caches available")
		http.NotFound(w, r)
		return
	}

	narinfo := findInCaches(r, b)
	if narinfo == nil {
		misses.Add(1)
		slog.Debug("no cache had store path", "path", r.URL.Path, "caches", b)
		http.NotFound(w, r)
		return
	}

	slog.Debug("cache hit", "url", narinfo.url)
	hits.Add(1)

	w.Header().Set("Content-Type", "text/x-nix-narinfo")
	w.Header().Set("nix-link", narinfo.url)
	fmt.Fprint(w, narinfo.body)
}
