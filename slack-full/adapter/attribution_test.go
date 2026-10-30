package main

import (
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"reflect"
	"strings"
	"sync"
	"testing"
)

// A user message an app posted under the user's id, with the app's
// "Sent using" footer in a context block.
func composedUserMsg() slackMessageEvent {
	return slackMessageEvent{
		Type: "message", Channel: "C1", User: "UOVERSEER", TS: "200.000001",
		Text:       "ship it",
		AppID:      "ACURSOR1",
		BotProfile: json.RawMessage(`{"app_id":"ACURSOR1","name":"Overseer"}`),
		Blocks: json.RawMessage(`[
			{"type":"rich_text","elements":[{"type":"rich_text_section"}]},
			{"type":"context","elements":[{"type":"mrkdwn","text":"*Sent using* <@UCURSORBOT|Cursor>"}]}
		]`),
	}
}

func TestSlackAttribution(t *testing.T) {
	cases := []struct {
		name string
		msg  slackMessageEvent
		want map[string]string
	}{
		{
			name: "plain human message carries only the speaker",
			msg:  slackMessageEvent{Type: "message", Channel: "C1", User: "UHUMAN1", TS: "1.0", Text: "hi"},
			want: map[string]string{"attribution_version": "1", "user_id": "UHUMAN1"},
		},
		{
			name: "app composing for a user",
			msg:  composedUserMsg(),
			want: map[string]string{
				"attribution_version": "1", "user_id": "UOVERSEER", "app_id": "ACURSOR1",
				"bot_profile_app_id": "ACURSOR1", "composer_user_id": "UCURSORBOT",
			},
		},
		{
			name: "trusted bot in its own voice",
			msg:  trustedBotMsg(tbTrusted),
			want: map[string]string{
				"attribution_version": "1", "user_id": tbTrustedUsr, "app_id": tbTrusted,
				"bot_id": tbTrustedBot, "bot_profile_app_id": tbTrusted,
			},
		},
		{
			name: "footer in the text, subtype kept",
			msg: slackMessageEvent{Type: "message", Subtype: "thread_broadcast", User: "U1", TS: "1.0",
				Text: "done\nSent using <@UAPPBOT>"},
			want: map[string]string{"attribution_version": "1", "user_id": "U1",
				"composer_user_id": "UAPPBOT", "subtype": "thread_broadcast"},
		},
		{
			name: "two different footers are both reported, sorted",
			msg: slackMessageEvent{Type: "message", User: "U1", TS: "1.0",
				Text:   "x Sent using <@UZED>",
				Blocks: json.RawMessage(`[{"type":"context","elements":[{"text":"Sent using <@UALPHA>"}]}]`)},
			want: map[string]string{"attribution_version": "1", "user_id": "U1", "composer_user_id": "UALPHA,UZED"},
		},
		{
			name: "a footer outside a context block is not read",
			msg: slackMessageEvent{Type: "message", User: "U1", TS: "1.0", Text: "x",
				Blocks: json.RawMessage(`[{"type":"section","elements":[{"text":"Sent using <@UALPHA>"}]}]`)},
			want: map[string]string{"attribution_version": "1", "user_id": "U1"},
		},
		{
			name: "malformed blocks do not break attribution",
			msg: slackMessageEvent{Type: "message", User: "U1", TS: "1.0", Text: "x",
				Blocks: json.RawMessage(`{"not":"a list"}`)},
			want: map[string]string{"attribution_version": "1", "user_id": "U1"},
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := slackAttribution(tc.msg); !reflect.DeepEqual(got, tc.want) {
				t.Errorf("slackAttribution = %v, want %v", got, tc.want)
			}
		})
	}
}

func TestAttributionLogTag(t *testing.T) {
	if got := attributionLogTag(map[string]string{"attribution_version": "1", "user_id": "U1"}); got != "" {
		t.Errorf("plain message tag = %q, want empty", got)
	}
	got := attributionLogTag(slackAttribution(composedUserMsg()))
	want := " composer=UCURSORBOT app_id=ACURSOR1 profile_app=ACURSOR1"
	if got != want {
		t.Errorf("tag = %q, want %q", got, want)
	}
}

// oldGCInbound answers like a gc older than fdce674d6: its inbound schema
// has additionalProperties=false, so a body with attribution is a 422.
type oldGCInbound struct {
	mu     sync.Mutex
	bodies []string
}

func (o *oldGCInbound) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	raw, _ := io.ReadAll(r.Body)
	o.mu.Lock()
	o.bodies = append(o.bodies, string(raw))
	o.mu.Unlock()
	if strings.Contains(string(raw), `"attribution"`) {
		w.Header().Set("Content-Type", "application/problem+json")
		w.WriteHeader(http.StatusUnprocessableEntity)
		_, _ = io.WriteString(w, `{"title":"Unprocessable Entity","status":422,"detail":"validation failed",`+
			`"errors":[{"message":"unexpected property","location":"body.message.attribution"}]}`)
		return
	}
	w.WriteHeader(http.StatusAccepted)
}

// TestPostInboundOldGCDropsAttributionOnce: an old gc refuses the field; the
// message is resent once without it and delivered, with a log line.
func TestPostInboundOldGCDropsAttributionOnce(t *testing.T) {
	o := &oldGCInbound{}
	srv := httptest.NewServer(o)
	t.Cleanup(srv.Close)
	cfg := config{gcAPIBase: srv.URL, cityName: "test-city"}
	cfg.inboundRetry, _ = recordSleeps(inboundRetryPolicy{})

	msg := testInboundMsg()
	msg.Attribution = map[string]string{"attribution_version": "1", "user_id": "U1"}
	read, restore := captureLog(t)
	err := postInbound(cfg, msg)
	logs := read()
	restore()
	if err != nil {
		t.Fatalf("postInbound: %v", err)
	}
	if len(o.bodies) != 2 {
		t.Fatalf("attempts = %d, want 2 (refused, then resent without attribution)", len(o.bodies))
	}
	if strings.Contains(o.bodies[1], "attribution") {
		t.Errorf("resend still carries attribution: %s", o.bodies[1])
	}
	if !strings.Contains(logs, "gc refused the attribution field") {
		t.Errorf("fallback not logged:\n%s", logs)
	}
}

// TestPostInboundOther4xxNotResent: a 4xx that does not name the field is
// the message's own fault, so it is neither retried nor resent.
func TestPostInboundOther4xxNotResent(t *testing.T) {
	f := &fakeInbound{failures: []int{http.StatusUnprocessableEntity}}
	cfg := newFakeInbound(t, f)
	cfg.inboundRetry, _ = recordSleeps(inboundRetryPolicy{})
	msg := testInboundMsg()
	msg.Attribution = map[string]string{"attribution_version": "1", "user_id": "U1"}
	if err := postInbound(cfg, msg); err == nil {
		t.Fatal("postInbound: want error, got nil")
	}
	if f.attempts != 1 {
		t.Errorf("attempts = %d, want 1", f.attempts)
	}
}

// TestPostInboundNoAttributionKeepsOldBody: absent attribution is not on
// the wire at all, so the body an old gc accepts is unchanged.
func TestPostInboundNoAttributionKeepsOldBody(t *testing.T) {
	f := &fakeInbound{}
	cfg := newFakeInbound(t, f)
	if err := postInbound(cfg, testInboundMsg()); err != nil {
		t.Fatalf("postInbound: %v", err)
	}
	if strings.Contains(f.bodies[0], "attribution") {
		t.Errorf("body without attribution mentions it: %s", f.bodies[0])
	}
}

// TestProcessSlackEventCarriesAttribution drives the legacy path end to end:
// the inbound body carries the event's composer evidence and the inbound:
// log line names it.
func TestProcessSlackEventCarriesAttribution(t *testing.T) {
	var mu sync.Mutex
	var got []map[string]string
	gcStub := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		raw, _ := io.ReadAll(r.Body)
		if strings.Contains(r.URL.Path, "/extmsg/inbound") {
			var req struct {
				Message externalInboundMessage `json:"message"`
			}
			_ = json.Unmarshal(raw, &req)
			mu.Lock()
			got = append(got, req.Message.Attribution)
			mu.Unlock()
		}
		w.WriteHeader(http.StatusAccepted)
	}))
	t.Cleanup(gcStub.Close)
	cfg := config{
		gcAPIBase:   gcStub.URL,
		cityName:    "test-city",
		provider:    "slack",
		accountID:   "T1",
		dispatchSem: defaultTestDispatchSem,
	}
	raw, _ := json.Marshal(composedUserMsg())
	env := slackEventEnvelope{Type: "event_callback", APIAppID: "ASELF", Event: raw}

	read, restore := captureLog(t)
	processSlackEvent(cfg, nil, nil, nil, nil, nil, env, func() {})
	logs := read()
	restore()

	mu.Lock()
	defer mu.Unlock()
	want := []map[string]string{slackAttribution(composedUserMsg())}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("posted attribution = %v, want %v", got, want)
	}
	if !strings.Contains(logs, "inbound: chan=C1 user=UOVERSEER ts=200.000001") ||
		!strings.Contains(logs, "composer=UCURSORBOT app_id=ACURSOR1") {
		t.Errorf("inbound line does not name the composer:\n%s", logs)
	}
}
