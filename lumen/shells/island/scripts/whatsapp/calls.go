// Calls, and messages this device cannot read.
//
// A linked device hears a call ring (CallOffer, or CallOfferNotice for a group's) and
// end (CallTerminate / CallReject), but cannot take it: WhatsApp Web shows who is
// calling and lets it be declined. So does this: {"t": "call"} while it rings, and a
// row of kind "call" in the chat when it ends ("Missed voice call", "Video call ·
// 2:14"). Calls from before linking come in the history as stubs (CALL_MISSED_*),
// and the phone may also send a CallLogMessage: one row per call either way.
//
//   in   {"op": "decline", "id": "…"}                     the call ringing now
//   out  {"t": "call", "on": true, "id": "…", "jid": "…", "name": "…", "video": false, "group": false}
//        {"t": "call", "on": false, "id": "…", "jid": "…"} it stopped ringing (answered, ended, declined)
//
// A message whose text did not arrive (the phone has to send it again) is a row
// of kind "waiting", replaced when it comes; a view-once one never comes to a
// linked device: a "note" says to open it on the phone.

package main

import (
	"fmt"
	"os"
	"strings"
	"sync"
	"time"

	"go.mau.fi/whatsmeow/proto/waE2E"
	"go.mau.fi/whatsmeow/proto/waWeb"
	"go.mau.fi/whatsmeow/types"
	"go.mau.fi/whatsmeow/types/events"
)

type call struct {
	id, jid, name  string
	from           types.JID // the device that called: declining goes to it
	video, group   bool
	rang, answered time.Time
	done           bool
}

var (
	callsMu sync.Mutex
	calls   = map[string]*call{}
)

// It rings.
func callOffer(meta types.BasicCallMeta, video, group bool) {
	chat := canon(meta.CallCreator, meta.CallCreatorAlt)
	if !meta.GroupJID.IsEmpty() {
		chat = meta.GroupJID
		group = true
	}
	if chat.IsEmpty() {
		chat = canon(meta.From, types.EmptyJID)
	}
	jid := chat.String()
	name := nameOf(canon(meta.CallCreator, meta.CallCreatorAlt), "")
	if group {
		name = groupName(chat)
	}
	callsMu.Lock()
	if _, dup := calls[meta.CallID]; dup {
		callsMu.Unlock()
		return
	}
	c := &call{id: meta.CallID, jid: jid, name: name, from: meta.From, video: video, group: group, rang: meta.Timestamp}
	if c.rang.IsZero() {
		c.rang = time.Now()
	}
	calls[meta.CallID] = c
	callsMu.Unlock()
	// What rang long ago (heard while catching up) is not ringing now.
	if time.Since(c.rang) < 75*time.Second {
		emit(map[string]any{"t": "call", "on": true, "id": c.id, "jid": jid, "name": name, "video": video, "group": group})
	}
	// Should its end never be heard: it stops ringing anyway, as a missed call.
	go func() {
		time.Sleep(75 * time.Second)
		callEnd(meta.CallID, "timeout")
	}()
}

// Taken, on the phone or another device.
func callAnswered(id string) {
	callsMu.Lock()
	c := calls[id]
	if c != nil && c.answered.IsZero() {
		c.answered = time.Now()
	}
	callsMu.Unlock()
	if c != nil {
		emit(map[string]any{"t": "call", "on": false, "id": id, "jid": c.jid})
	}
}

// It ended: the row it leaves in the chat.
func callEnd(id, reason string) {
	callsMu.Lock()
	c := calls[id]
	if c == nil || c.done {
		callsMu.Unlock()
		return
	}
	c.done = true
	callsMu.Unlock()
	emit(map[string]any{"t": "call", "on": false, "id": id, "jid": c.jid})
	r := strings.ToLower(reason)
	answered := !c.answered.IsZero() || strings.Contains(r, "accept")
	declined := strings.Contains(r, "reject") || strings.Contains(r, "decline")
	secs := 0
	if !c.answered.IsZero() {
		secs = int(time.Since(c.answered).Seconds())
	}
	saveCall(c.jid, "call-"+id, c.rang.Unix(), false, c.video, c.group, answered, declined, secs, true)
	// Gone after a while: the row is what remains.
	go func() {
		time.Sleep(5 * time.Minute)
		callsMu.Lock()
		delete(calls, id)
		callsMu.Unlock()
	}()
}

func decline(id string) {
	callsMu.Lock()
	c := calls[id]
	callsMu.Unlock()
	if c == nil || cli == nil {
		return
	}
	if err := cli.RejectCall(ctx, c.from, id); err != nil {
		emit(map[string]any{"t": "done", "op": "decline", "ok": false, "msg": "Couldn't decline: " + err.Error()})
		return
	}
	callEnd(id, "rejected")
}

// What a call says in its row (`me`: one made from this account).
func callText(me, video, group, answered, declined bool, secs int) string {
	what := "voice call"
	if video {
		what = "video call"
	}
	if group {
		what = "group " + what
	}
	switch {
	case answered && secs > 0:
		return fmt.Sprintf("%s · %d:%02d", strings.ToUpper(what[:1])+what[1:], secs/60, secs%60)
	case answered:
		return strings.ToUpper(what[:1]) + what[1:]
	case me:
		return strings.ToUpper(what[:1]) + what[1:] + " · No answer"
	case declined:
		return "Declined " + what
	}
	return "Missed " + what
}

// A call's row, once: the same call heard twice (live, then as a call log or in the history) is one row.
func saveCall(jid, id string, ts int64, me, video, group, answered, declined bool, secs int, live bool) {
	var near int
	db.QueryRow(`SELECT COUNT(*) FROM msgs WHERE chat = ? AND kind = 'call' AND ABS(ts - ?) < 120`, jid, ts).Scan(&near)
	if near > 0 {
		return
	}
	text := callText(me, video, group, answered, declined, secs)
	missed := !answered && !me
	r := row{Chat: jid, ID: id, Me: me, Text: text, TS: ts, Kind: "call", St: b2i(me), Seen: !live || !missed}
	if !r.save(nil) {
		return
	}
	if !live {
		return
	}
	// A missed call counts as unread, as on the phone.
	db.Exec(`INSERT INTO chats (jid, ts, grp, unread) VALUES (?, ?, ?, ?)
		ON CONFLICT (jid) DO UPDATE SET ts = MAX(ts, excluded.ts), unread = unread + excluded.unread`, jid, ts, b2i(group), b2i(missed))
	touch()
	name := ""
	if j, err := types.ParseJID(jid); err == nil {
		if group {
			name = groupName(j)
		} else {
			name = nameOf(j, "")
		}
	}
	var muted int
	db.QueryRow(`SELECT muted FROM chats WHERE jid = ?`, jid).Scan(&muted)
	emit(map[string]any{"t": "msg", "jid": jid, "name": name, "live": missed, "muted": muted != 0, "msg": r.json()})
}

// The call log the phone sends after a call (also for ones made from it).
func callLog(jid, id string, ts int64, me bool, l *waE2E.CallLogMessage, live bool) {
	o := l.GetCallOutcome()
	answered := o == waE2E.CallLogMessage_CONNECTED || o == waE2E.CallLogMessage_ACCEPTED_ELSEWHERE || o == waE2E.CallLogMessage_ONGOING
	declined := o == waE2E.CallLogMessage_REJECTED
	saveCall(jid, id, ts, me, l.GetIsVideo(), false, answered, declined, int(l.GetDurationSecs()), live)
}

// From the history: a call missed before this device was linked, as a row. True if it was one.
func callStub(jid string, wm *waWeb.WebMessageInfo) bool {
	t := wm.GetMessageStubType()
	video := t == waWeb.WebMessageInfo_CALL_MISSED_VIDEO || t == waWeb.WebMessageInfo_CALL_MISSED_GROUP_VIDEO
	group := t == waWeb.WebMessageInfo_CALL_MISSED_GROUP_VOICE || t == waWeb.WebMessageInfo_CALL_MISSED_GROUP_VIDEO
	if !video && !group && t != waWeb.WebMessageInfo_CALL_MISSED_VOICE {
		return false
	}
	saveCall(jid, wm.GetKey().GetID(), int64(wm.GetMessageTimestamp()), wm.GetKey().GetFromMe(), video, group, false, false, 0, false)
	return true
}

// A message that came without what it says: kept as "waiting" until it is sent again (whatsmeow asks for
// it), or, if it is a view-once one, as a note: those are for the phone only.
func undecryptable(e *events.UndecryptableMessage) {
	info := e.Info
	alt := info.SenderAlt
	if info.IsFromMe {
		alt = info.RecipientAlt
	}
	chat := canon(info.Chat, alt)
	if skipChat(chat) || info.ID == "" {
		return
	}
	jid := chat.String()
	text, kind := "Waiting for this message. This may take a while.", "waiting"
	if e.UnavailableType == events.UnavailableTypeViewOnce {
		text, kind = "View once message · open it on your phone", "viewonce"
	}
	sender := canon(info.Sender, info.SenderAlt)
	r := row{Chat: jid, ID: info.ID, Sender: sender.String(), Me: info.IsFromMe, Text: text, TS: info.Timestamp.Unix(), Kind: kind, St: b2i(info.IsFromMe), Seen: info.IsFromMe}
	if info.IsGroup && !info.IsFromMe {
		r.SName = nameOf(sender, info.PushName)
	}
	if !r.save(nil) {
		return
	}
	db.Exec(`INSERT INTO chats (jid, ts, grp, unread) VALUES (?, ?, ?, ?)
		ON CONFLICT (jid) DO UPDATE SET ts = MAX(ts, excluded.ts), unread = unread + excluded.unread`, jid, r.TS, b2i(info.IsGroup), b2i(!info.IsFromMe))
	touch()
	if syncing.Load() {
		return
	}
	name := r.SName
	if info.IsGroup {
		name = groupName(chat)
	} else if !info.IsFromMe {
		name = nameOf(sender, info.PushName)
	}
	// A view-once one is news (as on the phone); a message still on its way is not yet.
	emit(map[string]any{"t": "msg", "jid": jid, "name": name, "live": kind == "viewonce", "msg": r.json()})
}

// What a view-once message is, in its row.
func viewOnce(m *waE2E.Message) (string, string) {
	what := "View once message"
	switch {
	case m.GetImageMessage() != nil:
		what = "View once photo"
	case m.GetVideoMessage() != nil:
		what = "View once video"
	case m.GetAudioMessage() != nil:
		what = "View once voice message"
	}
	return what + " · open it on your phone", "viewonce"
}

// Asks the phone again for messages that came without what they say, or of a kind this did not
// know (it may now): each answer comes as a message and takes its place. The last two weeks, once
// a connection.
func askAgain() {
	if cli == nil {
		return
	}
	rows, err := db.Query(`SELECT chat, id, sender, me FROM msgs WHERE kind IN ('waiting', 'unsupported') AND ts > ? ORDER BY ts DESC LIMIT 30`, time.Now().Add(-14*24*time.Hour).Unix())
	if err != nil {
		return
	}
	type ask struct {
		chat, id, sender string
		me               bool
	}
	var list []ask
	for rows.Next() {
		var a ask
		rows.Scan(&a.chat, &a.id, &a.sender, &a.me)
		list = append(list, a)
	}
	rows.Close() // before sending: the store holds one connection
	for _, a := range list {
		chat, err1 := types.ParseJID(a.chat)
		sender, err2 := types.ParseJID(a.sender)
		if a.me || err2 != nil {
			sender = cli.Store.GetJID().ToNonAD()
			err2 = nil
		}
		if err1 != nil || err2 != nil {
			continue
		}
		if _, err := cli.SendPeerMessage(ctx, cli.BuildUnavailableMessageRequest(chat, sender, a.id)); err != nil {
			fmt.Fprintf(os.Stderr, "lumen-wa: asking the phone again for %s: %v\n", a.id, err)
		}
	}
}
