package main

import (
	"encoding/json"
	"errors"
	"regexp"
	"sort"
	"strings"
	"sync/atomic"
)

// Composer attribution on the inbound payload (gc-packs gp-599fr).
//
// A Slack message's speaker (`user`) is not its composer. An app can post
// under a user's id with a user token, and a "Sent using <@U…>" context
// block names the app's bot user. Until now the inbound payload carried only
// the speaker, so a seat's wake could not tell the overseer typing from a
// foreign app posting as him; the city's authority helper had to re-read the
// message from Slack to find out.
//
// gc (gascity fdce674d6, ga-5rtds) accepts an optional `attribution` map of
// adapter-defined strings on /extmsg/inbound, persists it with the transcript
// entry, prints it in the wake reminder and returns it from
// GET /extmsg/transcript?provider_message_id=…. It is adapter-asserted
// evidence; authority decisions stay with the consuming pack.
//
// Keys (attributionVersion "1"). A key is present only when Slack set the
// field; the map's presence with attribution_version says the adapter looked,
// so an absent key means Slack had no such field:
//
//	attribution_version  "1"
//	user_id              event `user` (the speaker)
//	app_id               event `app_id`
//	bot_id               event `bot_id`
//	bot_profile_app_id   event `bot_profile.app_id`
//	composer_user_id     the bot user in "Sent using <@U…>" (context blocks or
//	                     text); several distinct ones are comma-joined, sorted
//	subtype              event `subtype`
//
// Display names (`username`, `bot_profile.name`) are never carried: a
// chat:write.customize app can post under any name.
const attributionVersion = "1"

// sentUsingPattern matches the footer Slack apps add when posting for a user.
// Kept in step with SENT_USING_RE in gasburger's authority.py.
var sentUsingPattern = regexp.MustCompile(`\*?Sent using\*?\s*<@([A-Z0-9]+)(?:\|[^>]*)?>`)

// slackContextBlock is the subset of a Block Kit block sentUsing reads.
type slackContextBlock struct {
	Type     string `json:"type"`
	Elements []struct {
		Text string `json:"text"`
	} `json:"elements"`
}

// sentUsingComposers returns the distinct bot users named in "Sent using"
// footers, sorted. Context blocks and the plain text are both read.
func sentUsingComposers(msg slackMessageEvent) []string {
	found := map[string]bool{}
	var blocks []slackContextBlock
	if len(msg.Blocks) > 0 && json.Unmarshal(msg.Blocks, &blocks) == nil {
		for _, b := range blocks {
			if b.Type != "context" {
				continue
			}
			for _, e := range b.Elements {
				for _, m := range sentUsingPattern.FindAllStringSubmatch(e.Text, -1) {
					found[m[1]] = true
				}
			}
		}
	}
	for _, m := range sentUsingPattern.FindAllStringSubmatch(msg.Text, -1) {
		found[m[1]] = true
	}
	out := make([]string, 0, len(found))
	for id := range found {
		out = append(out, id)
	}
	sort.Strings(out)
	return out
}

// slackAttribution derives the inbound attribution map from a Slack message
// event. It reads only what the event carries; no Slack API call.
func slackAttribution(msg slackMessageEvent) map[string]string {
	attr := map[string]string{"attribution_version": attributionVersion}
	set := func(key, value string) {
		if value != "" {
			attr[key] = value
		}
	}
	set("user_id", msg.User)
	set("app_id", msg.AppID)
	set("bot_id", msg.BotID)
	set("bot_profile_app_id", parseSlackBotProfile(msg.BotProfile).AppID)
	set("composer_user_id", strings.Join(sentUsingComposers(msg), ","))
	set("subtype", msg.Subtype)
	return attr
}

// attributionLogTag renders the composer fields for the `inbound:` log line:
// ` composer=U… app_id=A… bot_id=B… profile_app=A…`, each only when set.
func attributionLogTag(attr map[string]string) string {
	var b strings.Builder
	for _, kv := range [][2]string{
		{"composer", "composer_user_id"},
		{"app_id", "app_id"},
		{"bot_id", "bot_id"},
		{"profile_app", "bot_profile_app_id"},
	} {
		if v := attr[kv[1]]; v != "" {
			b.WriteString(" " + kv[0] + "=" + v)
		}
	}
	return b.String()
}

// attributionDisabled latches for the life of the process after the first
// old-gc refusal of message.attribution. While set, postInbound omits the
// field so later messages do not pay another 422. It clears only on restart.
var attributionDisabled atomic.Bool

// attributionRejected reports whether gc refused the request because it does
// not know the attribution field: a gc that predates the field validates the
// inbound body with additionalProperties=false and answers 422 (or 400)
// naming the field. Any other 4xx is the message's own fault.
func attributionRejected(err error) bool {
	var se *inboundStatusError
	if !errors.As(err, &se) {
		return false
	}
	return (se.code == 422 || se.code == 400) && strings.Contains(se.body, "attribution")
}
