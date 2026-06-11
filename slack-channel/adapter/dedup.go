package main

import (
	"crypto/sha256"
	"encoding/hex"
	"strings"
	"sync"
	"time"
)

// postDedupTTL bounds how long a delivered post receipt is remembered for
// idempotent replay. It only needs to span the retry-after-timeout window:
// the verb HTTP client times out at 30s and an agent retry follows shortly
// after, so a couple of minutes comfortably covers the reported failure
// mode (gpk-bm3f / gpk-lbhl) while staying short enough that an intentional
// identical resend minutes later is not silently swallowed.
const postDedupTTL = 2 * time.Minute

// postReceipt is the uniform success body server.post returns for publish /
// publish-to-channel / reply-current. It is also the value the dedup cache
// replays on a retry, so a deduped retry response is byte-identical to the
// original post's.
type postReceipt struct {
	OK              bool   `json:"ok"`
	TS              string `json:"ts"`
	Channel         string `json:"channel"`
	IdentityApplied string `json:"identity_applied"`
}

// postDedupCache remembers delivered post receipts keyed by the caller's
// idempotency key, so a retry after a delivered-but-timed-out POST returns
// the original receipt instead of posting a second Slack message
// (gpk-bm3f). Only delivered (ok) receipts are cached: a retry after a
// genuine failure must still re-attempt delivery, so failures are never
// remembered. An empty idempotency key disables dedup for that call.
type postDedupCache struct {
	mu      sync.Mutex
	entries map[string]postDedupEntry
	ttl     time.Duration
	now     func() time.Time
}

type postDedupEntry struct {
	receipt   postReceipt
	expiresAt time.Time
}

func newPostDedupCache(ttl time.Duration) *postDedupCache {
	return &postDedupCache{
		entries: make(map[string]postDedupEntry),
		ttl:     ttl,
		now:     time.Now,
	}
}

// Get returns the cached receipt for key when one is present and unexpired.
func (c *postDedupCache) Get(key string) (postReceipt, bool) {
	if key == "" {
		return postReceipt{}, false
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	e, ok := c.entries[key]
	if !ok {
		return postReceipt{}, false
	}
	if !c.now().Before(e.expiresAt) {
		delete(c.entries, key)
		return postReceipt{}, false
	}
	return e.receipt, true
}

// Put records a delivered receipt under key and sweeps expired entries so
// the map stays bounded under churn. Empty keys and non-delivered receipts
// are ignored.
func (c *postDedupCache) Put(key string, receipt postReceipt) {
	if key == "" || !receipt.OK {
		return
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	now := c.now()
	c.entries[key] = postDedupEntry{receipt: receipt, expiresAt: now.Add(c.ttl)}
	for k, e := range c.entries {
		if !now.Before(e.expiresAt) {
			delete(c.entries, k)
		}
	}
}

// deriveReplyIdempotencyKey derives a stable key from a reply's identifying
// fields. When reply-current is called without an explicit --idempotency-key,
// a retry of the *same* logical reply (same session, resolved channel, thread
// anchor and body) must reuse the same key so the adapter dedupes the second
// post instead of duplicating it after a delivered-but-timed-out POST
// (gpk-bm3f). Unlike slack-full — where the verb script resolves the
// conversation and fingerprints client-side — slack-channel resolves the
// channel/thread inside the adapter, so the key is derived here, where those
// values are known.
func deriveReplyIdempotencyKey(sessionID, channel, threadTS, body string) string {
	fingerprint := strings.Join([]string{sessionID, channel, threadTS, body}, "\x00")
	sum := sha256.Sum256([]byte(fingerprint))
	return "reply-current:" + hex.EncodeToString(sum[:])
}
