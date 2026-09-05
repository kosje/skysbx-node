// Command node runs a skysb data plane: it dials its panel, applies whatever
// configuration it is given, and reports traffic back.
//
// It has no configuration file and no listening control port. Everything it
// needs is a panel URL and a token, and everything it serves is decided by the
// panel.
package main

import (
	"context"
	"flag"
	"fmt"
	"log/slog"
	"os"
	"os/signal"
	"strings"
	"syscall"

	"github.com/kosje/skysb-node/internal/engine"
	"github.com/kosje/skysb-node/internal/link"
)

// version is stamped at build time with -ldflags "-X main.version=...".
var version = "dev"

func main() {
	var (
		panelURL = flag.String("panel", envOr("SKYSB_PANEL", ""),
			"panel base URL, e.g. https://panel.example.com")
		token = flag.String("token", envOr("SKYSB_TOKEN", ""),
			"node token issued by the panel")
		logLevel = flag.String("log", envOr("SKYSB_LOG", "info"),
			"log level: debug, info, warn, error")
		showVersion = flag.Bool("version", false, "print the version and exit")
	)
	flag.Parse()

	if *showVersion {
		fmt.Printf("skysb-node %s (sing-box %s)\n", version, engine.New(nil).SingboxVersion())
		return
	}

	log := newLogger(*logLevel)

	// The token is a bearer credential, so it is accepted from the environment
	// as well as a flag: a command line is visible to every process on the host.
	if *panelURL == "" || *token == "" {
		log.Error("both a panel URL and a token are required",
			"hint", "pass -panel and -token, or set SKYSB_PANEL and SKYSB_TOKEN")
		os.Exit(2)
	}

	eng := engine.New(log)
	defer eng.Close()

	client, err := link.New(link.Config{
		PanelURL: *panelURL,
		Token:    *token,
		Version:  version,
		Engine:   eng,
		Log:      log,
	})
	if err != nil {
		log.Error("configure control channel", "error", err)
		os.Exit(2)
	}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	log.Info("starting", "version", version, "sing-box", eng.SingboxVersion(), "panel", *panelURL)

	// Run only returns when the context is cancelled; every network failure in
	// between is its own business.
	if err := client.Run(ctx); err != nil && ctx.Err() == nil {
		log.Error("control channel stopped", "error", err)
		os.Exit(1)
	}
	log.Info("shutting down")
}

func newLogger(level string) *slog.Logger {
	var l slog.Level
	if err := l.UnmarshalText([]byte(strings.ToLower(level))); err != nil {
		l = slog.LevelInfo
	}
	return slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: l}))
}

func envOr(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}
