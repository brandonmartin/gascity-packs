package main

import (
	"context"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

// TestHandleHealthzReportsDroppedCounter pins the /healthz body shape:
// the first line stays exactly "ok" (status-code and grep checks keep
// working), the second line carries the cumulative dropped-dispatch
// counter, and a saturated acquire is reflected on the next probe.
func TestHandleHealthzReportsDroppedCounter(t *testing.T) {
	before := dispatchDroppedTotal.Load()

	w := httptest.NewRecorder()
	handleHealthz(w, httptest.NewRequest(http.MethodGet, "/healthz", nil))
	if w.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200", w.Code)
	}
	lines := strings.Split(strings.TrimRight(w.Body.String(), "\n"), "\n")
	if len(lines) != 2 || lines[0] != "ok" {
		t.Fatalf("body = %q, want first line exactly \"ok\" plus counter line", w.Body.String())
	}
	if want := fmt.Sprintf("dispatch_dropped_total=%d", before); lines[1] != want {
		t.Errorf("counter line = %q, want %q", lines[1], want)
	}

	// Saturate a cap-1 sem: the failed acquire must bump the counter.
	cfg := config{dispatchSem: make(chan struct{}, 1)}
	release, _, ok := cfg.acquireDispatchSlot()
	if !ok {
		t.Fatal("acquireDispatchSlot: failed to take initial slot in fresh sem")
	}
	defer release()
	if _, _, ok := cfg.acquireDispatchSlot(); ok {
		t.Fatal("second acquire on cap-1 sem succeeded, want saturation")
	}

	w2 := httptest.NewRecorder()
	handleHealthz(w2, httptest.NewRequest(http.MethodGet, "/healthz", nil))
	if want := fmt.Sprintf("dispatch_dropped_total=%d", before+1); !strings.Contains(w2.Body.String(), want) {
		t.Errorf("healthz after drop = %q, want it to contain %q", w2.Body.String(), want)
	}
}

// TestRunDispatchDropSummaryLogsOnNewDrops verifies the periodic
// roll-up fires once new drops accumulate and includes the configured
// capacity, then stops cleanly on ctx cancel.
func TestRunDispatchDropSummaryLogsOnNewDrops(t *testing.T) {
	read, cleanup := captureLog(t)
	t.Cleanup(cleanup)

	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() {
		runDispatchDropSummary(ctx, 5*time.Millisecond, 7)
		close(done)
	}()
	// Drain the goroutine before captureLog's cleanup swaps the log
	// writer back, whatever path the test exits through.
	t.Cleanup(func() { cancel(); <-done })

	dispatchDroppedTotal.Add(3)

	// captureLog's buffer is unsynchronized, so don't read while the
	// goroutine may still write: give it a few ticks, then stop and
	// drain before the single read below.
	time.Sleep(100 * time.Millisecond)
	cancel()
	<-done

	logs := read()
	if !strings.Contains(logs, "dispatch saturation summary") {
		t.Fatalf("log missing saturation summary line:\n%s", logs)
	}
	if !strings.Contains(logs, "cap=7") {
		t.Errorf("summary line missing cap=7:\n%s", logs)
	}
	if !strings.Contains(logs, "dropped=") {
		t.Errorf("summary line missing dropped= delta:\n%s", logs)
	}
}
