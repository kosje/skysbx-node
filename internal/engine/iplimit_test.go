package engine

import (
	"slices"
	"testing"
	"time"
)

func ids(conns []conn, user string, ips ...string) []string {
	var out []string
	for _, c := range conns {
		if c.User == user && slices.Contains(ips, c.IP) {
			out = append(out, c.ID)
		}
	}
	slices.Sort(out)
	return out
}

// The addresses that keep their place are the ones seen earliest. Any other
// rule flaps: with "keep the newest", two devices take turns cutting each other
// off forever, and neither works.
func TestTheEarliestAddressesKeepTheirPlace(t *testing.T) {
	l := newLimiter()
	l.setLimits(map[string]int{"alice": 2})

	t0 := time.Unix(1_700_000_000, 0)

	// Two addresses, under the limit: nothing is closed.
	first := []conn{
		{ID: "1", User: "alice", IP: "10.0.0.1"},
		{ID: "2", User: "alice", IP: "10.0.0.1"},
		{ID: "3", User: "alice", IP: "10.0.0.2"},
	}
	closed, counts := l.enforce(first, t0)
	if len(closed) != 0 {
		t.Fatalf("closed %v while under the limit", closed)
	}
	if counts["alice"] != 2 {
		t.Fatalf("counted %d addresses, want 2", counts["alice"])
	}

	// A third address turns up later. It is the one that goes.
	second := append(slices.Clone(first),
		conn{ID: "4", User: "alice", IP: "10.0.0.3"},
		conn{ID: "5", User: "alice", IP: "10.0.0.3"})
	closed, counts = l.enforce(second, t0.Add(time.Second))
	want := ids(second, "alice", "10.0.0.3")
	slices.Sort(closed)
	if !slices.Equal(closed, want) {
		t.Errorf("closed %v, want the newcomer's connections %v", closed, want)
	}
	if counts["alice"] != 3 {
		t.Errorf("counted %d addresses, want 3 — the count is what is there, "+
			"not what is allowed", counts["alice"])
	}

	// And it stays the one that goes. The decision must not rotate between
	// polls, or every device works one second in three.
	for i := 2; i < 6; i++ {
		closed, _ = l.enforce(second, t0.Add(time.Duration(i)*time.Second))
		slices.Sort(closed)
		if !slices.Equal(closed, want) {
			t.Fatalf("poll %d closed %v, want %v — the decision flapped", i, closed, want)
		}
	}
}

// A user who idles briefly must not lose their slot to whoever connects next,
// or the paying customer is the one who ends up locked out.
func TestAnIdleAddressKeepsItsSlotForAWhile(t *testing.T) {
	l := newLimiter()
	l.setLimits(map[string]int{"alice": 1})

	t0 := time.Unix(1_700_000_000, 0)
	l.enforce([]conn{{ID: "1", User: "alice", IP: "10.0.0.1"}}, t0)

	// The first address goes quiet; a second one arrives.
	second := []conn{{ID: "2", User: "alice", IP: "10.0.0.2"}}
	closed, _ := l.enforce(second, t0.Add(ipGrace/2))
	if !slices.Equal(closed, []string{"2"}) {
		t.Errorf("closed %v, want the newcomer while the first is still in grace", closed)
	}

	// Past the grace period the slot is free, and the newcomer keeps it.
	closed, _ = l.enforce(second, t0.Add(2*ipGrace))
	if len(closed) != 0 {
		t.Errorf("closed %v after the first address expired", closed)
	}
}

// No limit means no limit — not a default, not a cap of one.
func TestNoLimitClosesNothing(t *testing.T) {
	l := newLimiter()
	l.setLimits(map[string]int{"alice": 0, "bob": -1})

	conns := []conn{
		{ID: "1", User: "alice", IP: "10.0.0.1"},
		{ID: "2", User: "alice", IP: "10.0.0.2"},
		{ID: "3", User: "alice", IP: "10.0.0.3"},
		{ID: "4", User: "bob", IP: "10.0.0.4"},
		{ID: "5", User: "carol", IP: "10.0.0.5"},
	}
	closed, counts := l.enforce(conns, time.Unix(1_700_000_000, 0))
	if len(closed) != 0 {
		t.Errorf("closed %v with no limits set", closed)
	}
	if counts["alice"] != 3 || counts["bob"] != 1 || counts["carol"] != 1 {
		t.Errorf("counts are wrong: %v", counts)
	}
}

// One user's limit must not touch another's connections.
func TestOneUsersLimitLeavesOthersAlone(t *testing.T) {
	l := newLimiter()
	l.setLimits(map[string]int{"alice": 1})

	conns := []conn{
		{ID: "1", User: "alice", IP: "10.0.0.1"},
		{ID: "2", User: "alice", IP: "10.0.0.2"},
		{ID: "3", User: "bob", IP: "10.0.0.2"},
		{ID: "4", User: "bob", IP: "10.0.0.3"},
	}
	closed, _ := l.enforce(conns, time.Unix(1_700_000_000, 0))
	slices.Sort(closed)
	if !slices.Equal(closed, []string{"2"}) {
		t.Errorf("closed %v, want only alice's second address", closed)
	}
}

// Deleting a user has to release what was remembered about them, or a panel
// that churns accounts leaks addresses for as long as the node runs.
func TestForgettingDeletedUsers(t *testing.T) {
	l := newLimiter()
	l.enforce([]conn{
		{ID: "1", User: "alice", IP: "10.0.0.1"},
		{ID: "2", User: "bob", IP: "10.0.0.2"},
	}, time.Unix(1_700_000_000, 0))

	l.forget(map[string]bool{"alice": true})

	l.mu.Lock()
	defer l.mu.Unlock()
	if _, ok := l.seen["bob"]; ok {
		t.Error("bob was deleted but is still remembered")
	}
	if _, ok := l.seen["alice"]; !ok {
		t.Error("alice still exists and should still be remembered")
	}
}

// Connections the API reports without a user or a source address cannot be
// attributed, and must not be counted against anyone.
func TestUnattributableConnectionsAreIgnored(t *testing.T) {
	l := newLimiter()
	l.setLimits(map[string]int{"alice": 1})

	closed, counts := l.enforce([]conn{
		{ID: "1", User: "", IP: "10.0.0.1"},
		{ID: "2", User: "alice", IP: ""},
		{ID: "3", User: "alice", IP: "10.0.0.9"},
	}, time.Unix(1_700_000_000, 0))

	if len(closed) != 0 {
		t.Errorf("closed %v", closed)
	}
	if counts["alice"] != 1 {
		t.Errorf("counted %d for alice, want 1", counts["alice"])
	}
	if _, ok := counts[""]; ok {
		t.Error("a connection with no user was counted against a nameless account")
	}
}
