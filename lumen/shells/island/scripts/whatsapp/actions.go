// What can be done to a message already there: reacted to, edited, deleted,
// forwarded, saved; and what is looked for in a chat: words (search), its
// pictures and files (the gallery), and the messages around one found.

package main

import (
	"context"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"time"

	"go.mau.fi/whatsmeow/proto/waE2E"
	"go.mau.fi/whatsmeow/types"
	"google.golang.org/protobuf/proto"
)

// Who sent a message, as WhatsApp's keys name it (the empty JID is us).
func senderOf(r row) types.JID {
	if r.Me {
		return types.EmptyJID
	}
	j, _ := types.ParseJID(r.Sender)
	return j
}

func sendCtx() (context.Context, context.CancelFunc) { return context.WithTimeout(ctx, 30*time.Second) }

func failed(op, jid, id, msg string) {
	emit(map[string]any{"t": "done", "op": op, "ok": false, "jid": jid, "id": id, "msg": msg})
}

// The reactions on a message, as the island shows them under it ("👍❤️ 3"), and ours.
func reactionsOf(jid, id string) (string, string) {
	rows, err := db.Query(`SELECT emoji, sender FROM reacts WHERE chat = ? AND msg = ? AND emoji != '' ORDER BY ts`, jid, id)
	if err != nil {
		return "", ""
	}
	defer rows.Close()
	var order []string
	seen := map[string]bool{}
	n := 0
	mine := ""
	for rows.Next() {
		var e, s string
		rows.Scan(&e, &s)
		n++
		if s == "me" {
			mine = e
		}
		if !seen[e] {
			seen[e] = true
			order = append(order, e)
		}
	}
	if n == 0 {
		return "", ""
	}
	if len(order) > 3 {
		order = order[:3]
	}
	sum := strings.Join(order, "")
	if n > 1 {
		sum += fmt.Sprintf(" %d", n)
	}
	return sum, mine
}

// Who reacted to a message with what, newest first: as WhatsApp's sheet lists them.
func whoReacted(jid, id string) {
	rows, err := db.Query(`SELECT emoji, sender FROM reacts WHERE chat = ? AND msg = ? AND emoji != '' ORDER BY ts DESC`, jid, id)
	if err != nil {
		return
	}
	// Read whole before names are looked up: the store has one connection.
	type one struct{ emoji, sender string }
	var got []one
	for rows.Next() {
		var o one
		if rows.Scan(&o.emoji, &o.sender) == nil {
			got = append(got, o)
		}
	}
	rows.Close()
	list := []map[string]any{}
	for _, o := range got {
		r := map[string]any{"emoji": o.emoji, "me": o.sender == "me", "name": "You", "pic": ""}
		if o.sender != "me" {
			if j, err := types.ParseJID(o.sender); err == nil {
				r["name"] = listName(j)
				if p := picPath(j); exists(p) {
					if st, _ := os.Stat(p); st != nil && st.Size() > 0 {
						r["pic"] = p
					}
				}
			}
		}
		list = append(list, r)
	}
	emit(map[string]any{"t": "reacts", "jid": jid, "id": id, "list": list})
}

// Someone's reaction (an empty one takes theirs back).
func keepReaction(jid, id, who, emoji string, ts int64) {
	if emoji == "" {
		db.Exec(`DELETE FROM reacts WHERE chat = ? AND msg = ? AND sender = ?`, jid, id, who)
	} else {
		db.Exec(`INSERT OR REPLACE INTO reacts (chat, msg, sender, emoji, ts) VALUES (?, ?, ?, ?, ?)`, jid, id, who, emoji, ts)
	}
}

func changed(jid, id string) {
	if r, ok := loadRow(jid, id); ok {
		emit(map[string]any{"t": "msg", "jid": jid, "live": false, "msg": r.json()})
	}
}

func react(jid, id, emoji string) {
	j, err := types.ParseJID(jid)
	r, ok := loadRow(jid, id)
	if err != nil || !ok {
		return
	}
	if !cli.IsConnected() {
		failed("react", jid, id, "Not connected")
		return
	}
	sctx, cancel := sendCtx()
	defer cancel()
	if _, err := cli.SendMessage(sctx, j, cli.BuildReaction(j, senderOf(r), id, emoji)); err != nil {
		fmt.Fprintf(os.Stderr, "lumen-wa react: %v\n", err)
		failed("react", jid, id, "Couldn't react")
		return
	}
	keepReaction(jid, id, "me", emoji, time.Now().Unix())
	changed(jid, id)
}

// Ours, what it says now (WhatsApp lets it change for a while after it was sent).
func edit(jid, id, text string) {
	text = strings.TrimSpace(text)
	j, err := types.ParseJID(jid)
	r, ok := loadRow(jid, id)
	if err != nil || !ok || !r.Me || text == "" {
		return
	}
	if !cli.IsConnected() {
		failed("edit", jid, id, "Not connected")
		changed(jid, id)
		return
	}
	sctx, cancel := sendCtx()
	defer cancel()
	if _, err := cli.SendMessage(sctx, j, cli.BuildEdit(j, id, &waE2E.Message{Conversation: proto.String(text)})); err != nil {
		fmt.Fprintf(os.Stderr, "lumen-wa edit: %v\n", err)
		failed("edit", jid, id, "Couldn't edit it")
		changed(jid, id)
		return
	}
	db.Exec(`UPDATE msgs SET text = ?, edited = 1 WHERE chat = ? AND id = ?`, text, jid, id)
	changed(jid, id)
	touch()
}

// Deleted for everyone (ours), or only here (anyone's).
func revoke(jid, id string) {
	j, err := types.ParseJID(jid)
	r, ok := loadRow(jid, id)
	if err != nil || !ok || !r.Me {
		return
	}
	if !cli.IsConnected() {
		failed("revoke", jid, id, "Not connected")
		return
	}
	sctx, cancel := sendCtx()
	defer cancel()
	if _, err := cli.SendMessage(sctx, j, cli.BuildRevoke(j, types.EmptyJID, id)); err != nil {
		fmt.Fprintf(os.Stderr, "lumen-wa revoke: %v\n", err)
		failed("revoke", jid, id, "Couldn't delete it")
		return
	}
	db.Exec(`UPDATE msgs SET text = 'You deleted this message', kind = 'deleted', media = '', raw = NULL WHERE chat = ? AND id = ?`, jid, id)
	db.Exec(`DELETE FROM reacts WHERE chat = ? AND msg = ?`, jid, id)
	changed(jid, id)
	touch()
}

func forget(jid, id string) {
	db.Exec(`DELETE FROM msgs WHERE chat = ? AND id = ?`, jid, id)
	db.Exec(`DELETE FROM reacts WHERE chat = ? AND msg = ?`, jid, id)
	emit(map[string]any{"t": "gone", "jid": jid, "id": id})
	touch()
}

// The context of whatever a message carries, so it can say it was forwarded.
func contextOf(m *waE2E.Message) **waE2E.ContextInfo {
	switch {
	case m.ImageMessage != nil:
		return &m.ImageMessage.ContextInfo
	case m.VideoMessage != nil:
		return &m.VideoMessage.ContextInfo
	case m.AudioMessage != nil:
		return &m.AudioMessage.ContextInfo
	case m.StickerMessage != nil:
		return &m.StickerMessage.ContextInfo
	case m.DocumentMessage != nil:
		return &m.DocumentMessage.ContextInfo
	case m.ExtendedTextMessage != nil:
		return &m.ExtendedTextMessage.ContextInfo
	}
	return nil
}

// A message, again, to another chat: its words, or its file as it is on WhatsApp's servers (nothing uploaded again).
func forward(from, id, to string) {
	j, err := types.ParseJID(to)
	r, ok := loadRow(from, id)
	if err != nil || !ok {
		return
	}
	if !cli.IsConnected() {
		failed("forward", to, id, "Not connected")
		return
	}
	var raw []byte
	db.QueryRow(`SELECT raw FROM msgs WHERE chat = ? AND id = ?`, from, id).Scan(&raw)
	msg := &waE2E.Message{}
	if len(raw) > 0 && proto.Unmarshal(raw, msg) == nil && contextOf(msg) != nil && msg.ExtendedTextMessage == nil {
		// what it answered stays behind
	} else {
		if r.Kind != "text" || r.Text == "" {
			failed("forward", to, id, "That can't be forwarded")
			return
		}
		msg = &waE2E.Message{ExtendedTextMessage: &waE2E.ExtendedTextMessage{Text: proto.String(r.Text)}}
	}
	*contextOf(msg) = &waE2E.ContextInfo{IsForwarded: proto.Bool(true), ForwardingScore: proto.Uint32(1)}
	sctx, cancel := sendCtx()
	defer cancel()
	resp, err := cli.SendMessage(sctx, j, msg)
	if err != nil {
		fmt.Fprintf(os.Stderr, "lumen-wa forward: %v\n", err)
		failed("forward", to, id, "Couldn't forward it")
		return
	}
	var keep []byte
	if r.Kind != "text" {
		keep, _ = proto.Marshal(msg)
	}
	m := row{Chat: to, ID: resp.ID, Me: true, Text: r.Text, TS: resp.Timestamp.Unix(), Kind: r.Kind, Media: r.Media, W: r.W, H: r.H, St: 1}
	m.save(keep)
	// Its preview too (the same picture): a copy under the new message's name.
	if p := previewPath(r.ID); exists(p) {
		if data, err := os.ReadFile(p); err == nil {
			os.WriteFile(previewPath(resp.ID), data, 0o600)
		}
	}
	db.Exec(`INSERT INTO chats (jid, ts) VALUES (?, ?) ON CONFLICT (jid) DO UPDATE SET ts = MAX(ts, excluded.ts), unread = 0`, to, m.TS)
	emit(map[string]any{"t": "msg", "jid": to, "live": false, "msg": m.json()})
	emit(map[string]any{"t": "done", "op": "forward", "ok": true, "jid": to, "id": id, "msg": "Forwarded to " + listName(j)})
	touch()
}

// The words looked for in a chat: the messages that say them, newest first.
func find(jid, q string) {
	q = strings.TrimSpace(q)
	hits := []map[string]any{}
	if q != "" {
		like := "%" + strings.NewReplacer(`\`, `\\`, `%`, `\%`, `_`, `\_`).Replace(q) + "%"
		rows, err := db.Query(`SELECT id, ts, me, sname, text FROM msgs WHERE chat = ? AND kind IN ('text', 'image', 'video', 'doc', 'note')
			AND text LIKE ? ESCAPE '\' ORDER BY ts DESC, rowid DESC LIMIT 200`, jid, like)
		if err == nil {
			for rows.Next() {
				var id, from, text string
				var ts int64
				var me int
				rows.Scan(&id, &ts, &me, &from, &text)
				hits = append(hits, map[string]any{"id": id, "ts": ts, "me": me != 0, "from": from, "text": text})
			}
			rows.Close()
		}
	}
	emit(map[string]any{"t": "found", "jid": jid, "q": q, "hits": hits})
}

// A message found far back, and those around it: 30 before it, 8 after.
func around(jid, id string) {
	older := queryMsgs(`SELECT `+rowCols+` FROM msgs WHERE chat = ? AND (ts, rowid) <=
		(SELECT ts, rowid FROM msgs WHERE chat = ? AND id = ?) ORDER BY ts DESC, rowid DESC LIMIT 31`, jid, jid, id)
	newer := queryMsgs(`SELECT `+rowCols+` FROM msgs WHERE chat = ? AND (ts, rowid) >
		(SELECT ts, rowid FROM msgs WHERE chat = ? AND id = ?) ORDER BY ts ASC, rowid ASC LIMIT 9`, jid, jid, id)
	// queryMsgs turns its rows around: the newer ones came oldest first, so they are newest first now.
	for i, k := 0, len(newer)-1; i < k; i, k = i+1, k-1 {
		newer[i], newer[k] = newer[k], newer[i]
	}
	newest := len(newer) < 9
	if !newest {
		newer = newer[:8]
	}
	emit(map[string]any{"t": "around", "jid": jid, "id": id, "msgs": append(older, newer...), "newest": newest})
	go fetchPictures(jid, append(older, newer...), 20)
}

// A chat's pictures, videos and stickers ("media") or its documents and voice notes ("files"), newest first.
func gallery(jid, kind string) {
	kinds := `('image', 'video', 'sticker')`
	if kind == "files" {
		kinds = `('doc', 'audio')`
	}
	list := queryMsgs(`SELECT `+rowCols+` FROM msgs WHERE chat = ? AND kind IN `+kinds+` ORDER BY ts ASC, rowid ASC LIMIT 400`, jid)
	emit(map[string]any{"t": "gallery", "jid": jid, "kind": kind, "items": list})
}

// Into ~/Downloads, under its own name (a number added when one is there already).
func save(jid, id string) {
	r, ok := loadRow(jid, id)
	if !ok {
		return
	}
	if r.Media == "" || strings.HasSuffix(r.Media, "-t.jpg") {
		fetchMedia(jid, id)
		r, _ = loadRow(jid, id)
	}
	if r.Media == "" || strings.HasSuffix(r.Media, "-t.jpg") {
		emit(map[string]any{"t": "saved", "jid": jid, "id": id, "path": "", "msg": "Couldn't download it"})
		return
	}
	home, _ := os.UserHomeDir()
	dir := filepath.Join(home, "Downloads")
	os.MkdirAll(dir, 0o755)
	ext := filepath.Ext(r.Media)
	base := ""
	if r.Kind == "doc" {
		base = strings.TrimSuffix(strings.SplitN(r.Text, "\n", 2)[0], ext)
		base = strings.Map(func(c rune) rune {
			if c == '/' || c == 0 {
				return '_'
			}
			return c
		}, base)
	}
	if base == "" {
		base = "WhatsApp " + map[string]string{"image": "Image", "video": "Video", "sticker": "Sticker", "audio": "Audio"}[r.Kind] +
			" " + time.Unix(r.TS, 0).Format("2006-01-02 at 15.04.05")
	}
	dest := filepath.Join(dir, base+ext)
	for n := 2; ; n++ {
		if _, err := os.Stat(dest); os.IsNotExist(err) {
			break
		}
		dest = filepath.Join(dir, fmt.Sprintf("%s (%d)%s", base, n, ext))
	}
	in, err := os.Open(r.Media)
	if err == nil {
		var outf *os.File
		if outf, err = os.Create(dest); err == nil {
			_, err = io.Copy(outf, in)
			outf.Close()
		}
		in.Close()
	}
	if err != nil {
		emit(map[string]any{"t": "saved", "jid": jid, "id": id, "path": "", "msg": "Couldn't save it"})
		return
	}
	emit(map[string]any{"t": "saved", "jid": jid, "id": id, "path": dest, "msg": "Saved to Downloads"})
}
