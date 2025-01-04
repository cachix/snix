// Package discovery provides logic for discovering the current set of available
// caches through Tailscale tags.
package discovery

import (
	"context"
	"fmt"
	"log/slog"
	"math/rand"
	"sync"
	"time"

	"tailscale.com/client/tailscale"

	"tvl.fyi/ops/builderball/config"
)

// GetCaches returns the currently known set of caches, updating it if required.
//
// If cached data is stale but an update fails, the stale data is returned
// anyways. There is a fairly high chance that one or more of the known caches
// are still alive in case of transient Tailscale issues.
func GetCaches() []string {
	return caches.get()
}

type cache struct {
	lock    sync.RWMutex
	caches  []string
	updated time.Time
}

var caches *cache = new(cache)

func (c *cache) update() ([]string, error) {
	c.lock.Lock()
	defer c.lock.Unlock()

	found := make([]string, len(config.Caches))
	copy(found, config.Caches)

	if *config.Tailscale {
		client := tailscale.LocalClient{}
		status, err := client.Status(context.Background())
		if err != nil {
			slog.Error("failed to get tailscale status", "error", err.Error())
			return nil, err
		}

		for _, peer := range status.Peer {
			if peer.Online && peer.Tags != nil && status.Self != peer && len(peer.TailscaleIPs) > 0 {
				for _, tag := range peer.Tags.All() {
					if tag == *config.TSTag {
						ip := peer.TailscaleIPs[0].String()
						slog.Debug("discovered cache on tailscale", "host", peer.HostName, "ip", ip)
						found = append(found, fmt.Sprintf("http://%s:%d", ip, *config.CachePort))
					}
				}
			}
		}
	}

	// shuffle order of elements to avoid sending everything to the first
	// configured one for popular packages
	rand.Shuffle(len(found), func(i, j int) {
		found[i], found[j] = found[j], found[i]
	})

	c.updated = time.Now()
	c.caches = make([]string, len(found))
	copy(c.caches, found)
	slog.Debug("updated discovered caches", "caches", found)

	return found, nil
}

func (c *cache) get() []string {
	c.lock.RLock()
	cached := make([]string, len(c.caches))
	copy(cached, c.caches)
	updated := c.updated
	c.lock.RUnlock()

	if time.Since(updated) > 30*time.Second {
		slog.Debug("discovery cache is stale; updating")
		result, err := c.update()
		if err != nil {
			// return stale results; worth trying anyways
			slog.Debug("returning stale discovery cache results")
			return cached
		}

		return result
	}

	return cached
}
