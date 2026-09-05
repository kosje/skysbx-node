// Package link maintains the control channel to the panel.
//
// The node dials out and keeps one WebSocket open. Reconnection is this
// package's business alone: nothing above it needs to know the channel dropped,
// because the panel re-sends the full configuration and user list on every
// hello. There is no resume protocol and no state to reconcile.
package link

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"math/rand/v2"
	"net/http"
	"net/url"
	"os"
	"runtime"
	"strings"
	"sync"
	"time"

	"github.com/coder/websocket"

	"github.com/kosje/skysb-node/internal/proto"
)

// Reporting intervals. Variables rather than constants so tests can shorten
// them; nothing in the running program writes to them.
var (
	statsEvery  = 30 * time.Second
	onlineEvery = 30 * time.Second
)

const (
	minBackoff = 1 * time.Second
	maxBackoff = 60 * time.Second

	// The panel pings every 30s. Three missed pings is a dead channel.
	readTimeout = 100 * time.Second

	maxFrame = 1 << 20
)

// Engine is the data plane, as the control channel needs to see it.
//
// Keeping it an interface is what lets the channel be tested against a fake
// panel without sing-box in the picture, and the data plane be tested without a
// network.
type Engine interface {
	// ApplyConfig replaces the running configuration. It rebuilds listeners and
	// therefore drops live connections, which is why users travel separately.
	ApplyConfig(ctx context.Context, config json.RawMessage) error

	// UpdateUsers swaps the user set on running inbounds without restarting
	// them, and refreshes the statistics allowlist.
	UpdateUsers(ctx context.Context, users proto.UsersData) error

	// Stats returns traffic since the last acknowledged report. It does not
	// advance the baseline; StatsReported does, once the report has actually
	// been written to the channel.
	Stats() (map[string]proto.Usage, *proto.SystemStats, error)

	// StatsReported acknowledges the last Stats result. Traffic that is read
	// but never reported must not be discarded — it is traffic nobody is
	// billed for.
	StatsReported()

	// Online lists users with at least one live connection.
	Online() ([]string, error)

	// SingboxVersion is reported in the hello.
	SingboxVersion() string
}

type Config struct {
	// PanelURL is the panel's base URL, e.g. https://panel.example.com.
	PanelURL string
	Token    string
	Version  string

	Engine Engine
	Log    *slog.Logger
}

type Client struct {
	cfg Config
	log *slog.Logger

	wsURL string

	mu sync.Mutex
	ws *websocket.Conn
}

func New(cfg Config) (*Client, error) {
	if cfg.PanelURL == "" {
		return nil, errors.New("panel URL is required")
	}
	if cfg.Token == "" {
		return nil, errors.New("node token is required")
	}
	if cfg.Engine == nil {
		return nil, errors.New("engine is required")
	}
	u, err := url.Parse(strings.TrimRight(cfg.PanelURL, "/"))
	if err != nil {
		return nil, fmt.Errorf("panel URL %q: %w", cfg.PanelURL, err)
	}
	switch u.Scheme {
	case "https":
		u.Scheme = "wss"
	case "http":
		u.Scheme = "ws"
	default:
		return nil, fmt.Errorf("panel URL %q must be http or https", cfg.PanelURL)
	}
	u.Path = strings.TrimRight(u.Path, "/") + "/api/v1/node/connect"

	log := cfg.Log
	if log == nil {
		log = slog.Default()
	}
	return &Client{cfg: cfg, log: log, wsURL: u.String()}, nil
}

// Run keeps the channel up until ctx is cancelled.
func (c *Client) Run(ctx context.Context) error {
	backoff := minBackoff
	for {
		err := c.session(ctx)
		if ctx.Err() != nil {
			return ctx.Err()
		}
		if err != nil {
			c.log.Warn("control channel lost", "error", err, "retry_in", backoff)
		}

		// Jitter matters when a panel restarts: without it every node it serves
		// reconnects in the same instant, which is the moment the panel can
		// least afford a thundering herd.
		wait := backoff + rand.N(backoff/2+time.Millisecond)
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(wait):
		}

		backoff *= 2
		if backoff > maxBackoff {
			backoff = maxBackoff
		}
	}
}

func (c *Client) session(ctx context.Context) error {
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()

	dialCtx, dialCancel := context.WithTimeout(ctx, 30*time.Second)
	defer dialCancel()

	ws, _, err := websocket.Dial(dialCtx, c.wsURL, &websocket.DialOptions{
		HTTPHeader: http.Header{"Authorization": {"Bearer " + c.cfg.Token}},
	})
	if err != nil {
		return fmt.Errorf("dial %s: %w", c.wsURL, err)
	}
	ws.SetReadLimit(maxFrame)
	defer ws.Close(websocket.StatusNormalClosure, "")

	c.mu.Lock()
	c.ws = ws
	c.mu.Unlock()
	defer func() {
		c.mu.Lock()
		c.ws = nil
		c.mu.Unlock()
	}()

	hostname, _ := os.Hostname()
	if err := c.send(ctx, proto.TypeHello, 0, proto.Hello{
		Version:        c.cfg.Version,
		OS:             runtime.GOOS,
		Arch:           runtime.GOARCH,
		Hostname:       hostname,
		SingboxVersion: c.cfg.Engine.SingboxVersion(),
	}); err != nil {
		return fmt.Errorf("hello: %w", err)
	}
	c.log.Info("control channel up", "panel", c.cfg.PanelURL)

	go c.report(ctx)

	for {
		readCtx, readCancel := context.WithTimeout(ctx, readTimeout)
		_, data, err := ws.Read(readCtx)
		readCancel()
		if err != nil {
			if ctx.Err() != nil {
				return nil
			}
			return err
		}
		c.handle(ctx, data)
	}
}

// handle processes one frame. A command that fails is reported back rather than
// logged and forgotten: the panel is the only place an operator will look, and
// it has no other way to learn the node did not adopt what it sent.
func (c *Client) handle(ctx context.Context, data []byte) {
	var env proto.Envelope
	if err := json.Unmarshal(data, &env); err != nil {
		c.log.Warn("malformed frame", "error", err)
		return
	}

	switch env.Type {
	case proto.TypeConfig:
		var cd proto.ConfigData
		if err := json.Unmarshal(env.Data, &cd); err != nil {
			c.reply(ctx, env.ID, fmt.Errorf("config payload: %w", err))
			return
		}
		err := c.cfg.Engine.ApplyConfig(ctx, cd.Config)
		if err != nil {
			c.log.Error("apply config", "error", err)
		} else {
			c.log.Info("configuration applied")
		}
		c.reply(ctx, env.ID, err)

	case proto.TypeUsers:
		var ud proto.UsersData
		if err := json.Unmarshal(env.Data, &ud); err != nil {
			c.reply(ctx, env.ID, fmt.Errorf("users payload: %w", err))
			return
		}
		err := c.cfg.Engine.UpdateUsers(ctx, ud)
		if err != nil {
			c.log.Error("update users", "error", err)
		} else {
			c.log.Debug("users updated", "tags", len(ud.ByTag), "stats", len(ud.StatsUsers))
		}
		c.reply(ctx, env.ID, err)

	case proto.TypePing:
		if err := c.send(ctx, proto.TypePong, env.ID, nil); err != nil {
			c.log.Debug("pong", "error", err)
		}

	default:
		c.log.Warn("unknown message type", "type", env.Type)
	}
}

func (c *Client) reply(ctx context.Context, id uint64, err error) {
	if err == nil {
		_ = c.send(ctx, proto.TypeOK, id, nil)
		return
	}
	_ = c.send(ctx, proto.TypeError, id, proto.ErrorData{Message: err.Error()})
}

// report pushes traffic and online users on a timer for as long as the session
// lasts.
func (c *Client) report(ctx context.Context) {
	statsTick := time.NewTicker(statsEvery)
	onlineTick := time.NewTicker(onlineEvery)
	defer statsTick.Stop()
	defer onlineTick.Stop()

	for {
		select {
		case <-ctx.Done():
			return

		case <-statsTick.C:
			users, system, err := c.cfg.Engine.Stats()
			if err != nil {
				c.log.Warn("read stats", "error", err)
				continue
			}
			if len(users) == 0 && system == nil {
				continue
			}
			if err := c.send(ctx, proto.TypeStats, 0,
				proto.StatsData{Users: users, System: system}); err != nil {
				// The session is gone; Run will reconnect. The baseline is
				// deliberately not advanced, so this interval is carried into
				// the next report rather than lost.
				return
			}
			c.cfg.Engine.StatsReported()

		case <-onlineTick.C:
			names, err := c.cfg.Engine.Online()
			if err != nil {
				c.log.Debug("read online users", "error", err)
				continue
			}
			if err := c.send(ctx, proto.TypeOnline, 0,
				proto.OnlineData{Users: names}); err != nil {
				return
			}
		}
	}
}

func (c *Client) send(ctx context.Context, msgType string, id uint64, data any) error {
	frame, err := proto.Encode(msgType, id, data)
	if err != nil {
		return err
	}

	// One writer at a time: the read loop replies to commands while the report
	// goroutine pushes stats.
	c.mu.Lock()
	ws := c.ws
	defer c.mu.Unlock()
	if ws == nil {
		return errors.New("control channel is down")
	}

	writeCtx, cancel := context.WithTimeout(ctx, 15*time.Second)
	defer cancel()
	return ws.Write(writeCtx, websocket.MessageText, frame)
}
