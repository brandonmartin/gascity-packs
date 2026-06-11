package main

import (
	"encoding/json"
	"net/http"
	"testing"
	"time"
)

func TestHandleReplyCurrentDedupesOnRetry(t *testing.T) {
	// gpk-bm3f: two identical reply-current calls (the shape of an agent
	// re-posting after a delivered-but-timed-out POST) must derive the same
	// key and post to Slack only once, replaying the original receipt.
	srv := newTestServer(t)
	slack := newSlackCollector(t, srv)
	srv.recordInbound("s1", inboundRef{channelID: "C1", messageTS: "70.1", threadTS: "70.0"})

	body := `{"session_id":"s1","body":"on it","thread_current":true}`
	first := doJSON(srv.handleReplyCurrent(), body)
	second := doJSON(srv.handleReplyCurrent(), body)

	if first.Code != http.StatusOK || second.Code != http.StatusOK {
		t.Fatalf("status = %d, %d; want 200, 200", first.Code, second.Code)
	}
	if len(slack.posts) != 1 {
		t.Fatalf("slack posts = %d, want 1 (retry must not re-post)", len(slack.posts))
	}
	// Both responses carry the same delivered receipt.
	for _, rec := range []string{first.Body.String(), second.Body.String()} {
		var got postReceipt
		if err := json.Unmarshal([]byte(rec), &got); err != nil {
			t.Fatalf("decode receipt %q: %v", rec, err)
		}
		if !got.OK || got.TS != "99.9" {
			t.Errorf("receipt = %+v, want ok with ts 99.9", got)
		}
	}
}

func TestHandleReplyCurrentNoDedupAcrossDifferentBodies(t *testing.T) {
	// Two genuinely different replies must NOT collapse — distinct bodies
	// fingerprint to distinct keys.
	srv := newTestServer(t)
	slack := newSlackCollector(t, srv)
	srv.recordInbound("s1", inboundRef{channelID: "C1", messageTS: "70.1", threadTS: "70.0"})

	doJSON(srv.handleReplyCurrent(), `{"session_id":"s1","body":"first","thread_current":true}`)
	doJSON(srv.handleReplyCurrent(), `{"session_id":"s1","body":"second","thread_current":true}`)
	if len(slack.posts) != 2 {
		t.Fatalf("slack posts = %d, want 2 (different bodies must not dedupe)", len(slack.posts))
	}
}

func TestHandlePublishDedupesOnIdempotencyKey(t *testing.T) {
	srv := newTestServer(t)
	slack := newSlackCollector(t, srv)
	mustBind(t, srv, "C1", "room", "s1")

	body := `{"session_id":"s1","body":"build green","idempotency_key":"k-1"}`
	first := doJSON(srv.handlePublish(), body)
	second := doJSON(srv.handlePublish(), body)
	if first.Code != http.StatusOK || second.Code != http.StatusOK {
		t.Fatalf("status = %d, %d; want 200, 200", first.Code, second.Code)
	}
	if len(slack.posts) != 1 {
		t.Fatalf("slack posts = %d, want 1 (same key must dedupe)", len(slack.posts))
	}
}

func TestHandlePublishNoDedupWithoutKey(t *testing.T) {
	srv := newTestServer(t)
	slack := newSlackCollector(t, srv)
	mustBind(t, srv, "C1", "room", "s1")

	body := `{"session_id":"s1","body":"hi"}`
	doJSON(srv.handlePublish(), body)
	doJSON(srv.handlePublish(), body)
	if len(slack.posts) != 2 {
		t.Fatalf("slack posts = %d, want 2 (no key => no dedup)", len(slack.posts))
	}
}

func TestHandlePublishFailureThenRetryWithKeyReachesSlack(t *testing.T) {
	// A failed post is never cached: a retry with the SAME key must still
	// re-attempt delivery (only delivered receipts dedupe). This is the
	// guarantee that a genuine failure is not silently swallowed by the
	// idempotency cache.
	srv := newTestServer(t)
	slack := newSlackCollector(t, srv)
	mustBind(t, srv, "C1", "room", "s1")

	body := `{"session_id":"s1","body":"hi","idempotency_key":"k-1"}`

	slack.postError = "channel_not_found"
	if rec := doJSON(srv.handlePublish(), body); rec.Code != http.StatusBadGateway {
		t.Fatalf("first publish status = %d, want 502", rec.Code)
	}

	slack.postError = "" // failure clears; the retry must reach Slack again
	if rec := doJSON(srv.handlePublish(), body); rec.Code != http.StatusOK {
		t.Fatalf("retry status = %d, want 200 (failure must not be cached)", rec.Code)
	}
	if len(slack.posts) != 2 {
		t.Fatalf("slack posts = %d, want 2 (failed post must not dedupe the retry)", len(slack.posts))
	}
}

func TestPostDedupCache(t *testing.T) {
	clock := time.Unix(1_700_000_000, 0)
	c := newPostDedupCache(2 * time.Minute)
	c.now = func() time.Time { return clock }

	delivered := postReceipt{OK: true, TS: "1.1", Channel: "C1"}

	// Empty key is never stored or matched.
	c.Put("", delivered)
	if _, ok := c.Get(""); ok {
		t.Error("empty key should never hit the cache")
	}

	// Non-delivered receipts are not cached: a retry must re-attempt.
	c.Put("fail", postReceipt{OK: false})
	if _, ok := c.Get("fail"); ok {
		t.Error("non-delivered receipt must not be cached")
	}

	// Delivered receipt is replayed within the TTL window.
	c.Put("k", delivered)
	got, ok := c.Get("k")
	if !ok || got.TS != "1.1" {
		t.Fatalf("Get(k) = %+v, %v; want cached delivered receipt", got, ok)
	}

	// Past the TTL the entry is gone (and lazily evicted).
	clock = clock.Add(2*time.Minute + time.Second)
	if _, ok := c.Get("k"); ok {
		t.Error("entry should have expired past its TTL")
	}
}

func TestDeriveReplyIdempotencyKey(t *testing.T) {
	a := deriveReplyIdempotencyKey("s1", "C1", "70.0", "hello")
	again := deriveReplyIdempotencyKey("s1", "C1", "70.0", "hello")
	if a != again {
		t.Errorf("key not stable: %q != %q", a, again)
	}
	if a == "" || a[:len("reply-current:")] != "reply-current:" {
		t.Errorf("key = %q, want non-empty reply-current: prefix", a)
	}
	// Any identifying field changing yields a different fingerprint.
	for _, diff := range []string{
		deriveReplyIdempotencyKey("s2", "C1", "70.0", "hello"),
		deriveReplyIdempotencyKey("s1", "C2", "70.0", "hello"),
		deriveReplyIdempotencyKey("s1", "C1", "71.0", "hello"),
		deriveReplyIdempotencyKey("s1", "C1", "70.0", "world"),
	} {
		if diff == a {
			t.Errorf("expected distinct key from %q, got collision", a)
		}
	}
}
