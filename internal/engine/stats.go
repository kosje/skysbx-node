package engine

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"strings"
	"sync"
	"time"

	"github.com/kosje/skysbx-node/internal/proto"
)

// counters turns sing-box's cumulative per-user totals into the deltas the
// panel expects.
//
// The panel accumulates what it is sent, so it must be sent differences. It
// cannot be sent totals: this process restarts, sing-box's counters start again
// at zero, and a total that goes backwards is indistinguishable from an
// operator resetting someone's usage.
type counters struct {
	mu sync.Mutex
	// reported is the baseline the last acknowledged report was measured
	// against; pending is the reading behind the report now in flight.
	reported map[string]proto.Usage
	pending  map[string]proto.Usage
}

func newCounters() *counters {
	return &counters{reported: map[string]proto.Usage{}}
}

func (c *counters) reset() {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.reported = map[string]proto.Usage{}
	c.pending = nil
}

// delta returns the change since the last acknowledged report. It does not move
// the baseline — commit does, once the report has actually reached the panel.
// Advancing here instead would discard an interval whenever the channel dropped
// between reading and sending, and traffic that is never reported is never
// billed.
func (c *counters) delta(now map[string]proto.Usage) map[string]proto.Usage {
	c.mu.Lock()
	defer c.mu.Unlock()

	out := make(map[string]proto.Usage, len(now))
	for name, cur := range now {
		before := c.reported[name]
		up, down := cur.Up-before.Up, cur.Down-before.Down

		// A counter that went backwards means sing-box reset it — a config
		// apply, or the user being removed and re-added. Treat the new value as
		// the whole delta rather than reporting a negative one, which the panel
		// refuses anyway.
		if up < 0 {
			up = cur.Up
		}
		if down < 0 {
			down = cur.Down
		}
		if up != 0 || down != 0 {
			out[name] = proto.Usage{Up: up, Down: down}
		}
	}
	c.pending = now
	return out
}

// commit accepts the reading behind the report that just succeeded.
//
// Names absent from it are dropped with the old map. A user removed and later
// re-added starts from zero, which is right: everything up to the removal has
// already been counted.
func (c *counters) commit() {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.pending != nil {
		c.reported = c.pending
		c.pending = nil
	}
}

// Stats reads the current per-user totals and returns the change since the last
// call. Calling it advances the baseline, so exactly one caller may do so.
func (e *Engine) Stats() (map[string]proto.Usage, *proto.SystemStats, error) {
	e.mu.Lock()
	running, ctx := e.running, e.ctx
	e.mu.Unlock()

	if !running {
		return nil, nil, nil
	}

	totals, err := e.readTotals(ctx)
	if err != nil {
		return nil, nil, err
	}
	return e.counters.delta(totals), systemStats(), nil
}

// StatsReported is called once the panel has acknowledged the last report, and
// is what advances the baseline. Until it is called, the traffic stays pending
// and is included again in the next report.
func (e *Engine) StatsReported() { e.counters.commit() }

// Online lists users with at least one live connection, read from the clash_api
// connection table.
func (e *Engine) Online() ([]string, error) {
	e.mu.Lock()
	running := e.running
	addr := e.apis.clash
	e.mu.Unlock()

	if !running || addr == "" {
		return nil, nil
	}

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	req, err := http.NewRequestWithContext(ctx, http.MethodGet,
		"http://"+addr+"/connections", nil)
	if err != nil {
		return nil, err
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return nil, fmt.Errorf("clash api: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("clash api returned %s", resp.Status)
	}

	var body struct {
		Connections []struct {
			Metadata struct {
				User string `json:"user"`
			} `json:"metadata"`
		} `json:"connections"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&body); err != nil {
		return nil, fmt.Errorf("clash api response: %w", err)
	}

	seen := map[string]bool{}
	var out []string
	for _, c := range body.Connections {
		name := strings.TrimSpace(c.Metadata.User)
		if name == "" || seen[name] {
			continue
		}
		seen[name] = true
		out = append(out, name)
	}
	return out, nil
}
