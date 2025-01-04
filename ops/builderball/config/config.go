package config

import (
	"flag"
	"strings"
)

var (
	Host     = flag.String("host", "localhost", "host on which to listen for incoming requests")
	Port     = flag.Int("port", 2243, "port on which to listen for incoming requests")
	Debug    = flag.Bool("debug", false, "whether debug logging should be enabled")
	JSON     = flag.Bool("json", false, "whether logging should be in JSON format")
	Ticker   = flag.Int("ticker", 5, "interval in seconds between statistics tickers")
	Priority = flag.Int("priority", 50, "Nix cache priority with which to serve clients")

	Tailscale = flag.Bool("tailscale", false, "whether caches should be discovered on Tailscale")
	TSTag     = flag.String("tailscale-tag", "tag:nix-cache", "Tailscale tag to use for discovery")

	CachePort = flag.Int("cache-port", 80, "port at which to connect to binary cache on each node")
	CacheHost = flag.String("cache-host", "", "Host header to send to each binary cache")

	Caches []string
)

type stringSliceFlag []string

func (s *stringSliceFlag) String() string {
	if len(*s) == 0 {
		return "[ ]"
	}

	return "[ " + strings.Join(*s, " ") + " ]"
}

func (s *stringSliceFlag) Set(value string) error {
	*s = append(*s, value)
	return nil
}

func init() {
	flag.Var((*stringSliceFlag)(&Caches), "cache", "Upstream cache URL (can be specified multiple times)")
}
