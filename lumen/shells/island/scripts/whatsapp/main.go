// The island's WhatsApp: one process that stays up, spawned by island.luau.
//
// It is a linked device of the phone's account (as WhatsApp Web is), through
// whatsmeow. WhatsApp keeps no history for a linked device, so what it hears
// (and the history the phone sends once, when it is linked) is kept here, in
// msgs.db. The island writes one JSON object per line on stdin and gets one
// per line back:
//
//   in   {"op": "pair"}                         a QR code to link it (only when asked: the view is open)
//        {"op": "open", "jid": "…"}             that chat's last messages
//        {"op": "send", "jid": "…", "text": "…"}
//        {"op": "file", "jid": "…", "path": "/…", "caption": "…"}   a picture, video, song or any file (also "tmp", "quote")
//        {"op": "read", "jid": "…"}             what came in there has been seen
//        {"op": "media", "jid": "…", "id": "…"} the whole picture, video or voice note, to a file
//        {"op": "typing", "jid": "…", "on": true}
//        {"op": "here", "on": true}             the view is open: online, as WhatsApp Web is while looked at
//        {"op": "react", "jid": "…", "id": "…", "emoji": "👍"}   "" takes ours back
//        {"op": "reacts", "jid": "…", "id": "…"}                 who reacted with what
//        {"op": "edit", "jid": "…", "id": "…", "text": "…"}      ours, what it says now
//        {"op": "revoke", "jid": "…", "id": "…"}                 ours, deleted for everyone
//        {"op": "forget", "jid": "…", "id": "…"}                 anyone's, deleted here only
//        {"op": "forward", "jid": "…", "id": "…", "to": "…"}
//        {"op": "find", "jid": "…", "q": "…"}                    the messages that say it
//        {"op": "around", "jid": "…", "id": "…"}                 a message found, and those around it
//        {"op": "gallery", "jid": "…", "kind": "media" | "files"}
//        {"op": "save", "jid": "…", "id": "…"}                   its file, into ~/Downloads
//        {"op": "file", …, "ptt": true, "secs": 4}               a voice note recorded here
//        {"op": "logout"}
//   out  {"t": "state", "state": "pair" | "qr" | "connecting" | "ok" | "offline", "msg": "…", "qr": "/…/qr-3.png"}
//        {"t": "chats", "unread": 4, "chats": [{jid, name, last, ts, unread, group, muted, pinned, pic}, …]}  pinned, then newest
//        {"t": "msgs", "jid": "…", "msgs": [{id, me, from, text, ts, kind, media, w, h, st}, …]}  oldest first
//        {"t": "msg", "jid": "…", "name": "…", "live": true, "muted": false, "msg": {…}}   one more, or one changed
//        {"t": "media", "jid": "…", "id": "…", "path": "…"}
//        {"t": "typing", "jid": "…", "on": true}
//        {"t": "done", "op": "send", "ok": true, "msg": "…"}
//        {"t": "gone", "jid": "…", "id": "…"}                    deleted here
//        {"t": "found", "jid": "…", "q": "…", "hits": [{id, ts, me, from, text}, …]}   newest first
//        {"t": "around", "jid": "…", "id": "…", "msgs": […], "newest": false}
//        {"t": "gallery", "jid": "…", "kind": "media", "items": […]}   oldest first
//        {"t": "saved", "jid": "…", "id": "…", "path": "…", "msg": "…"}
//        {"t": "reacts", "jid": "…", "id": "…", "list": [{emoji, name, pic, me}, …]}   newest first
//        {"t": "sync", "on": true, "done": 40, "total": 312}     catching up after being away; "on": false once caught up
//   A message also carries "react" ("👍❤️ 3"), "mine" (our reaction) and "edited".
//
// Kept outside the dotfiles: ~/.local/share/lumen/whatsapp (the device's keys
// and the messages; mode 700) and ~/.cache/lumen/whatsapp (QR codes, media,
// profile pictures). Build: `go build -o ~/.local/share/lumen/whatsapp/lumen-wa .`

package main

import (
	"bufio"
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"reflect"
	"runtime/debug"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"

	_ "github.com/mattn/go-sqlite3"
	"github.com/skip2/go-qrcode"
	"go.mau.fi/whatsmeow"
	"go.mau.fi/whatsmeow/proto/waE2E"
	"go.mau.fi/whatsmeow/proto/waMmsRetry"
	"go.mau.fi/whatsmeow/store/sqlstore"
	"go.mau.fi/whatsmeow/types"
	"go.mau.fi/whatsmeow/types/events"
	waLog "go.mau.fi/whatsmeow/util/log"
	"golang.org/x/sys/unix"
	"google.golang.org/protobuf/proto"
)

var (
	ctx      = context.Background()
	cli      *whatsmeow.Client
	db       *sql.DB
	dataDir  string
	cacheDir string

	outMu sync.Mutex
	out   = bufio.NewWriter(os.Stdout)

	dirtyMu sync.Mutex
	dirty   bool // the chat list changed: sent again within a moment

	pairing bool       // a QR channel is open
	pairMu  sync.Mutex // …one at a time
	qrSeq   int

	groupNames sync.Map // jid → name, asked of WhatsApp once a run
	picMu      sync.Mutex
	picAsked   = map[string]bool{}
	picSlots   = make(chan struct{}, 2) // two asked at a time, as a browser would

	// Catching up after being away (the phone used meanwhile): what WhatsApp kept for this device
	// comes all at once. It is kept quietly —no message, list or banner each— and the island is
	// told how far along it is, then sent everything once.
	syncing   atomic.Bool
	syncTotal atomic.Int64
	syncDone  atomic.Int64
	syncRun   atomic.Int64

	fetchMu      sync.Mutex
	fetching     = map[string]bool{}        // chat/id: media on its way
	retrying     = map[string]string{}      // id → chat: media the phone was asked to send again
	previewSlots = make(chan struct{}, 2)   // ffmpeg making previews, two at a time
)

// Only what goes wrong, to stderr: stdout is the island's.
type errLog struct{ mod string }

func (l errLog) Errorf(f string, a ...any) {
	fmt.Fprintf(os.Stderr, "lumen-wa %s: "+f+"\n", append([]any{l.mod}, a...)...)
}
func (l errLog) Warnf(f string, a ...any)  {}
func (l errLog) Infof(f string, a ...any)  {}
func (l errLog) Debugf(f string, a ...any) {}
func (l errLog) Sub(m string) waLog.Logger { return errLog{l.mod + "/" + m} }

func emit(v map[string]any) {
	b, err := json.Marshal(v)
	if err != nil {
		return
	}
	outMu.Lock()
	out.Write(b)
	out.WriteByte('\n')
	out.Flush()
	outMu.Unlock()
}

func state(s, msg string) { emit(map[string]any{"t": "state", "state": s, "msg": msg}) }

func main() {
	// The island ending ends this too, however it ends.
	unix.Prctl(unix.PR_SET_PDEATHSIG, uintptr(syscall.SIGTERM), 0, 0, 0)
	debug.SetGCPercent(50)
	debug.SetMemoryLimit(48 << 20)

	home, _ := os.UserHomeDir()
	dataDir = filepath.Join(home, ".local/share/lumen/whatsapp")
	cacheDir = filepath.Join(home, ".cache/lumen/whatsapp")
	os.MkdirAll(dataDir, 0o700)
	os.MkdirAll(filepath.Join(cacheDir, "media"), 0o700)
	os.Chmod(dataDir, 0o700)
	// What goes wrong, where it can be read afterwards (the island does not keep a helper's stderr).
	if f, err := os.OpenFile(filepath.Join(cacheDir, "helper.log"), os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0o600); err == nil {
		os.Stderr = f
	}
	// Old QR codes are of no use to anyone.
	if old, _ := filepath.Glob(filepath.Join(cacheDir, "qr-*.png")); old != nil {
		for _, f := range old {
			os.Remove(f)
		}
	}

	var err error
	db, err = sql.Open("sqlite3", "file:"+filepath.Join(dataDir, "msgs.db")+"?_journal_mode=WAL&_busy_timeout=4000")
	if err != nil {
		state("offline", "Can't open the message store")
		os.Exit(1)
	}
	db.SetMaxOpenConns(1)
	schema()

	container, err := sqlstore.New(ctx, "sqlite3", "file:"+filepath.Join(dataDir, "session.db")+"?_foreign_keys=on&_busy_timeout=4000", errLog{"store"})
	if err != nil {
		state("offline", "Can't open the session")
		os.Exit(1)
	}
	device, err := container.GetFirstDevice(ctx)
	if err != nil {
		state("offline", "Can't open the session")
		os.Exit(1)
	}
	cli = whatsmeow.NewClient(device, errLog{"client"})
	cli.AddEventHandler(handle)
	cli.EnableAutoReconnect = true

	sigs := make(chan os.Signal, 1)
	signal.Notify(sigs, syscall.SIGTERM, syscall.SIGINT, syscall.SIGHUP)
	go func() {
		<-sigs
		quit(0)
	}()

	go flusher()
	sendChats()

	if cli.Store.ID == nil {
		state("pair", "Link WhatsApp from your phone")
	} else {
		go connect()
	}

	in := bufio.NewScanner(os.Stdin)
	in.Buffer(make([]byte, 1<<20), 1<<20)
	for in.Scan() {
		var op map[string]any
		if json.Unmarshal(in.Bytes(), &op) != nil {
			continue
		}
		if o, _ := op["op"].(string); o != "" {
			fmt.Fprintln(os.Stderr, "lumen-wa op:", o)
		}
		go command(op)
	}
	quit(0) // stdin closed: the island is gone
}

// connect keeps trying until the first connection is made: at login the
// network is often not up yet, and whatsmeow's auto-reconnect only covers a
// connection that once worked.
func connect() {
	wait := 2 * time.Second
	for {
		state("connecting", "Connecting…")
		err := cli.Connect()
		if err == nil || cli.IsConnected() {
			return
		}
		fmt.Fprintln(os.Stderr, "lumen-wa connect:", err)
		state("offline", "Can't reach WhatsApp, trying again…")
		time.Sleep(wait)
		wait = min(wait*2, 30*time.Second)
	}
}

func quit(code int) {
	if cli != nil {
		cli.Disconnect()
	}
	if db != nil {
		db.Close()
	}
	os.Exit(code)
}

func schema() {
	db.Exec(`CREATE TABLE IF NOT EXISTS chats (
		jid TEXT PRIMARY KEY, name TEXT NOT NULL DEFAULT '', unread INTEGER NOT NULL DEFAULT 0,
		ts INTEGER NOT NULL DEFAULT 0, grp INTEGER NOT NULL DEFAULT 0, muted INTEGER NOT NULL DEFAULT 0,
		pinned INTEGER NOT NULL DEFAULT 0, archived INTEGER NOT NULL DEFAULT 0)`)
	db.Exec(`CREATE TABLE IF NOT EXISTS msgs (
		chat TEXT NOT NULL, id TEXT NOT NULL, sender TEXT NOT NULL DEFAULT '', sname TEXT NOT NULL DEFAULT '',
		me INTEGER NOT NULL DEFAULT 0, text TEXT NOT NULL DEFAULT '', ts INTEGER NOT NULL DEFAULT 0,
		kind TEXT NOT NULL DEFAULT 'text', media TEXT NOT NULL DEFAULT '', w INTEGER NOT NULL DEFAULT 0,
		h INTEGER NOT NULL DEFAULT 0, st INTEGER NOT NULL DEFAULT 0, seen INTEGER NOT NULL DEFAULT 1,
		raw BLOB, PRIMARY KEY (chat, id))`)
	db.Exec(`CREATE INDEX IF NOT EXISTS msgs_ts ON msgs (chat, ts)`)
	// What a message answers (a quoted reply): who said it, and what (the first line). Added later: an older store gets them now.
	db.Exec(`ALTER TABLE msgs ADD COLUMN qfrom TEXT NOT NULL DEFAULT ''`)
	db.Exec(`ALTER TABLE msgs ADD COLUMN qtext TEXT NOT NULL DEFAULT ''`)
	db.Exec(`ALTER TABLE msgs ADD COLUMN edited INTEGER NOT NULL DEFAULT 0`)
	// The id of the message a reply answers: its picture shows small in the quote.
	db.Exec(`ALTER TABLE msgs ADD COLUMN qid TEXT NOT NULL DEFAULT ''`)
	// Who reacted to what with what ("me" for us).
	db.Exec(`CREATE TABLE IF NOT EXISTS reacts (chat TEXT NOT NULL, msg TEXT NOT NULL, sender TEXT NOT NULL,
		emoji TEXT NOT NULL, ts INTEGER NOT NULL DEFAULT 0, PRIMARY KEY (chat, msg, sender))`)
	db.Exec(`UPDATE chats SET ts = COALESCE((SELECT MAX(ts) FROM msgs WHERE chat = chats.jid), 0) WHERE ts = 0`)
}

// ── what the island asks ──────────────────────────────────────────

func command(op map[string]any) {
	str := func(k string) string { s, _ := op[k].(string); return s }
	switch str("op") {
	case "pair":
		pair()
	case "open":
		sendMsgs(str("jid"))
	case "send":
		send(str("jid"), str("text"), str("tmp"), str("quote"))
	case "file":
		// Uploading takes a while: the list and the chat go on meanwhile.
		secs, _ := op["secs"].(float64)
		ptt, _ := op["ptt"].(bool)
		go sendFile(str("jid"), str("path"), str("caption"), str("tmp"), str("quote"), ptt, uint32(secs))
	case "older":
		before, _ := op["before"].(string)
		sendOlder(str("jid"), before)
	case "read":
		markRead(str("jid"))
	case "media":
		go fetchMedia(str("jid"), str("id")) // a big video must not hold up what is asked after it
	case "reacts":
		whoReacted(str("jid"), str("id"))
	case "react":
		go react(str("jid"), str("id"), str("emoji"))
	case "edit":
		go edit(str("jid"), str("id"), str("text"))
	case "revoke":
		go revoke(str("jid"), str("id"))
	case "forget":
		forget(str("jid"), str("id"))
	case "forward":
		go forward(str("jid"), str("id"), str("to"))
	case "find":
		find(str("jid"), str("q"))
	case "around":
		around(str("jid"), str("id"))
	case "gallery":
		gallery(str("jid"), str("kind"))
	case "save":
		go save(str("jid"), str("id"))
	case "typing":
		if j, err := types.ParseJID(str("jid")); err == nil && cli.IsLoggedIn() {
			on, _ := op["on"].(bool)
			st := types.ChatPresencePaused
			if on {
				st = types.ChatPresenceComposing
			}
			cli.SendChatPresence(ctx, j, st, types.ChatPresenceMediaText)
		}
	case "here":
		if cli.IsLoggedIn() && cli.Store.PushName != "" {
			on, _ := op["on"].(bool)
			p := types.PresenceUnavailable
			if on {
				p = types.PresenceAvailable
			}
			cli.SendPresence(ctx, p)
		}
	case "logout":
		cli.Logout(ctx)
		db.Exec(`DELETE FROM msgs`)
		db.Exec(`DELETE FROM chats`)
		state("pair", "Logged out")
		quit(0)
	}
}

// A QR code to scan from the phone (Settings → Linked devices), a new one
// every twenty seconds or so, until it is scanned or WhatsApp gives up.
func pair() {
	pairMu.Lock()
	if pairing || cli.Store.ID != nil {
		pairMu.Unlock()
		return
	}
	pairing = true
	pairMu.Unlock()
	defer func() { pairMu.Lock(); pairing = false; pairMu.Unlock() }()

	qr, err := cli.GetQRChannel(ctx)
	if err != nil {
		state("pair", "Can't link right now")
		return
	}
	if err := cli.Connect(); err != nil {
		state("pair", "Can't reach WhatsApp")
		return
	}
	for item := range qr {
		switch item.Event {
		case "code":
			qrSeq++
			path := filepath.Join(cacheDir, fmt.Sprintf("qr-%d.png", qrSeq))
			if q, err := qrcode.New(item.Code, qrcode.Medium); err == nil {
				q.DisableBorder = true
				if q.WriteFile(560, path) == nil {
					os.Remove(filepath.Join(cacheDir, fmt.Sprintf("qr-%d.png", qrSeq-1)))
					emit(map[string]any{"t": "state", "state": "qr", "qr": path, "msg": "Scan with WhatsApp on your phone"})
				}
			}
		case "success":
			state("connecting", "Linked. Fetching your chats…")
			return
		case "timeout":
			cli.Disconnect()
			state("pair", "The code expired")
			return
		default:
			if item.Error != nil {
				cli.Disconnect()
				state("pair", "Couldn't link: "+item.Error.Error())
				return
			}
		}
	}
}

// A message, answering another (`quote`, its id) if it says so: WhatsApp shows that one above it.
func send(jid, text, tmp, quote string) {
	text = strings.TrimSpace(text)
	j, err := types.ParseJID(jid)
	if err != nil || text == "" {
		return
	}
	if !cli.IsConnected() {
		fmt.Fprintln(os.Stderr, "lumen-wa send: not connected")
		emit(map[string]any{"t": "done", "op": "send", "ok": false, "jid": jid, "tmp": tmp, "msg": "Not connected"})
		return
	}
	sctx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	msg := &waE2E.Message{Conversation: proto.String(text)}
	ci, qfrom, qtext := quoting(jid, quote)
	if ci != nil {
		msg = &waE2E.Message{ExtendedTextMessage: &waE2E.ExtendedTextMessage{Text: proto.String(text), ContextInfo: ci}}
	}
	resp, err := cli.SendMessage(sctx, j, msg)
	if err != nil {
		fmt.Fprintf(os.Stderr, "lumen-wa send to %s: %v\n", j.Server, err)
		emit(map[string]any{"t": "done", "op": "send", "ok": false, "jid": jid, "tmp": tmp, "msg": "Couldn't send"})
		return
	}
	m := row{Chat: jid, ID: resp.ID, Me: true, Text: text, TS: resp.Timestamp.Unix(), Kind: "text", St: 1, QFrom: qfrom, QText: qtext}
	if ci != nil {
		m.QID = quote
	}
	m.save(nil)
	db.Exec(`INSERT INTO chats (jid, ts) VALUES (?, ?) ON CONFLICT (jid) DO UPDATE SET ts = MAX(ts, excluded.ts), unread = 0`, jid, m.TS)
	emit(map[string]any{"t": "msg", "jid": jid, "live": false, "tmp": tmp, "msg": m.json()})
	emit(map[string]any{"t": "done", "op": "send", "ok": true, "jid": jid, "tmp": tmp})
	touch()
}

// What a message sent answers (r): the context that quotes it, and who said it and
// its first line, as the island shows it. Nil when it answers nothing.
func quoting(jid, quote string) (*waE2E.ContextInfo, string, string) {
	q, ok := loadRow(jid, quote)
	if !ok || quote == "" {
		return nil, "", ""
	}
	participant := q.Sender
	if q.Me && cli.Store.ID != nil {
		participant = cli.Store.ID.ToNonAD().String()
	}
	qfrom, qtext := q.SName, firstLine(q.Text, q.Kind)
	if q.Me {
		qfrom = "You"
	} else if qfrom == "" {
		if pj, err := types.ParseJID(q.Sender); err == nil {
			qfrom = listName(pj)
		}
	}
	// The message itself when it is kept (a picture quoted shows as one, with its small picture); else its words.
	qm := &waE2E.Message{Conversation: proto.String(q.Text)}
	var raw []byte
	if db.QueryRow(`SELECT raw FROM msgs WHERE chat = ? AND id = ?`, jid, quote).Scan(&raw) == nil && len(raw) > 0 {
		var whole waE2E.Message
		if proto.Unmarshal(raw, &whole) == nil {
			qm = &whole
		}
	}
	return &waE2E.ContextInfo{
		StanzaID:      proto.String(quote),
		Participant:   proto.String(participant),
		QuotedMessage: qm,
	}, qfrom, qtext
}

// Read receipts for what came in, one receipt for each sender (as groups need).
func markRead(jid string) {
	j, err := types.ParseJID(jid)
	if err != nil {
		return
	}
	rows, err := db.Query(`SELECT id, sender, ts FROM msgs WHERE chat = ? AND me = 0 AND seen = 0`, jid)
	if err != nil {
		return
	}
	by := map[string][]types.MessageID{}
	var last int64
	for rows.Next() {
		var id, sender string
		var ts int64
		rows.Scan(&id, &sender, &ts)
		by[sender] = append(by[sender], id)
		if ts > last {
			last = ts
		}
	}
	rows.Close()
	db.Exec(`UPDATE msgs SET seen = 1 WHERE chat = ? AND me = 0 AND seen = 0`, jid)
	db.Exec(`UPDATE chats SET unread = 0 WHERE jid = ?`, jid)
	touch()
	if !cli.IsConnected() {
		return
	}
	for sender, ids := range by {
		s, _ := types.ParseJID(sender)
		if !j.IsEmpty() && j.Server == types.DefaultUserServer {
			s = types.EmptyJID
		}
		cli.MarkRead(ctx, ids, time.Unix(last, 0), j, s)
	}
}

// The whole picture, video, voice note or file, to a file (once: asked twice
// while it comes, it comes once). A picture or a video also gets its preview
// (`-p.jpg`): what the chat draws, never the file itself.
func fetchMedia(jid, id string) {
	key := jid + "/" + id
	fetchMu.Lock()
	if fetching[key] {
		fetchMu.Unlock()
		return
	}
	fetching[key] = true
	fetchMu.Unlock()
	defer func() {
		fetchMu.Lock()
		delete(fetching, key)
		fetchMu.Unlock()
	}()
	var raw []byte
	var kind, have string
	if db.QueryRow(`SELECT raw, kind, media FROM msgs WHERE chat = ? AND id = ?`, jid, id).Scan(&raw, &kind, &have) != nil {
		return
	}
	done := func(path string) {
		r, ok := loadRow(jid, id)
		if !ok {
			return
		}
		emit(map[string]any{"t": "media", "jid": jid, "id": id, "path": path, "pic": r.pic(), "file": r.file()})
	}
	if whole(have) {
		if _, err := os.Stat(have); err == nil {
			preview(id, kind, have)
			done(have)
			return
		}
	}
	var m waE2E.Message
	if len(raw) == 0 || proto.Unmarshal(raw, &m) != nil {
		return
	}
	ext := map[string]string{"image": ".jpg", "video": ".mp4", "audio": ".ogg", "sticker": ".webp"}[kind]
	var dm whatsmeow.DownloadableMessage
	switch kind {
	case "image":
		dm = m.GetImageMessage()
	case "video":
		dm = m.GetVideoMessage()
	case "audio":
		dm = m.GetAudioMessage()
	case "sticker":
		dm = m.GetStickerMessage()
	case "doc":
		dm = m.GetDocumentMessage()
		ext = filepath.Ext(m.GetDocumentMessage().GetFileName())
	}
	path := filepath.Join(cacheDir, "media", safe(id)+ext)
	// Straight to the disk (a video is not held in memory), under another name until it is whole.
	part := path + ".part"
	f, err := os.OpenFile(part, os.O_CREATE|os.O_RDWR|os.O_TRUNC, 0o600)
	if err == nil {
		if dm == nil || reflect.ValueOf(dm).IsNil() {
			err = errors.New("nothing to download")
		} else {
			err = cli.DownloadToFile(ctx, dm, f)
		}
		f.Close()
	}
	if err == nil {
		err = os.Rename(part, path)
	}
	if err != nil {
		os.Remove(part)
		// Older than WhatsApp's servers keep it (history, mostly): the phone is asked to send it again.
		// (403 too: that is what an expired link answers here.)
		if errors.Is(err, whatsmeow.ErrMediaDownloadFailedWith403) || errors.Is(err, whatsmeow.ErrMediaDownloadFailedWith404) ||
			errors.Is(err, whatsmeow.ErrMediaDownloadFailedWith410) || errors.Is(err, whatsmeow.ErrNoURLPresent) {
			if askPhone(jid, id, dm) {
				return
			}
		}
		fmt.Fprintf(os.Stderr, "lumen-wa media %s: %v\n", kind, err)
		emit(map[string]any{"t": "media", "jid": jid, "id": id, "path": "", "msg": "Couldn't download it"})
		return
	}
	db.Exec(`UPDATE msgs SET media = ? WHERE chat = ? AND id = ?`, path, jid, id)
	preview(id, kind, path)
	done(path)
}

// Asks the phone to put a message's media up again (once): the answer is a
// MediaRetry event, with where it is now.
func askPhone(jid, id string, dm whatsmeow.DownloadableMessage) bool {
	fetchMu.Lock()
	_, asked := retrying[id]
	if !asked {
		retrying[id] = jid
	}
	fetchMu.Unlock()
	if asked {
		return false
	}
	// Asked again later if the phone says nothing (off, or WhatsApp closed there) or had not
	// got it then: it may have it once the picture is opened on the phone.
	go func() {
		time.Sleep(2 * time.Minute)
		fetchMu.Lock()
		delete(retrying, id)
		fetchMu.Unlock()
	}()
	chat, err := types.ParseJID(jid)
	if err != nil {
		return false
	}
	var sender string
	var me int
	db.QueryRow(`SELECT sender, me FROM msgs WHERE chat = ? AND id = ?`, jid, id).Scan(&sender, &me)
	info := &types.MessageInfo{ID: id, MessageSource: types.MessageSource{Chat: chat, IsFromMe: me != 0, IsGroup: chat.Server == types.GroupServer}}
	if s, err := types.ParseJID(sender); err == nil {
		info.Sender = s
	}
	if err := cli.SendMediaRetryReceipt(ctx, info, dm.GetMediaKey()); err != nil {
		fmt.Fprintf(os.Stderr, "lumen-wa media retry: %v\n", err)
		return false
	}
	fmt.Fprintf(os.Stderr, "lumen-wa media retry: asked the phone for %s\n", id)
	return true
}

// The phone's answer: the media is up again, at a new path (or it no longer has it).
func mediaRetried(e *events.MediaRetry) {
	fetchMu.Lock()
	jid, ok := retrying[e.MessageID]
	fetchMu.Unlock()
	if !ok {
		return
	}
	var raw []byte
	if db.QueryRow(`SELECT raw FROM msgs WHERE chat = ? AND id = ?`, jid, e.MessageID).Scan(&raw) != nil {
		return
	}
	var m waE2E.Message
	if proto.Unmarshal(raw, &m) != nil {
		return
	}
	var key []byte
	var setPath func(string)
	switch {
	case m.ImageMessage != nil:
		key, setPath = m.ImageMessage.GetMediaKey(), func(p string) { m.ImageMessage.DirectPath = proto.String(p) }
	case m.VideoMessage != nil:
		key, setPath = m.VideoMessage.GetMediaKey(), func(p string) { m.VideoMessage.DirectPath = proto.String(p) }
	case m.AudioMessage != nil:
		key, setPath = m.AudioMessage.GetMediaKey(), func(p string) { m.AudioMessage.DirectPath = proto.String(p) }
	case m.DocumentMessage != nil:
		key, setPath = m.DocumentMessage.GetMediaKey(), func(p string) { m.DocumentMessage.DirectPath = proto.String(p) }
	case m.StickerMessage != nil:
		key, setPath = m.StickerMessage.GetMediaKey(), func(p string) { m.StickerMessage.DirectPath = proto.String(p) }
	default:
		return
	}
	n, err := whatsmeow.DecryptMediaRetryNotification(e, key)
	if err != nil || n.GetResult() != waMmsRetry.MediaRetryNotification_SUCCESS || n.GetDirectPath() == "" {
		fmt.Fprintf(os.Stderr, "lumen-wa media retry answer for %s: %v %v\n", e.MessageID, err, n.GetResult())
		emit(map[string]any{"t": "media", "jid": jid, "id": e.MessageID, "path": "", "msg": "Not on your phone: open it in WhatsApp there, then here again"})
		return
	}
	fmt.Fprintf(os.Stderr, "lumen-wa media retry answer for %s: sent again\n", e.MessageID)
	setPath(n.GetDirectPath())
	if b, err := proto.Marshal(&m); err == nil {
		db.Exec(`UPDATE msgs SET raw = ? WHERE chat = ? AND id = ?`, b, jid, e.MessageID)
	}
	fetchMedia(jid, e.MessageID) // `retrying` still holds it: a second failure is not asked again
}

// Whether a message's media is the whole file (not WhatsApp's small blurred one).
func whole(media string) bool { return media != "" && !strings.HasSuffix(media, "-t.jpg") }

func previewPath(id string) string { return filepath.Join(cacheDir, "media", safe(id)+"-p.jpg") }

// What the chat draws of a picture or a video: the picture, or the video's first
// frame, at most 640 pixels on its longer side (a bubble is 280 wide, at the
// screen's scale). Decoding a whole photo for every bubble held up the text.
func preview(id, kind, src string) {
	if kind != "image" && kind != "video" {
		return
	}
	dst := previewPath(id)
	if _, err := os.Stat(dst); err == nil {
		return
	}
	previewSlots <- struct{}{}
	defer func() { <-previewSlots }()
	scale := "scale='if(gt(iw,ih),min(640,iw),-2)':'if(gt(iw,ih),-2,min(640,ih))'"
	tmp := dst + ".part.jpg"
	cmd := exec.Command("ffmpeg", "-v", "error", "-y", "-i", src, "-frames:v", "1", "-vf", scale, "-q:v", "3", tmp)
	if err := cmd.Run(); err != nil {
		os.Remove(tmp)
		fmt.Fprintf(os.Stderr, "lumen-wa preview %s: %v\n", kind, err)
		return
	}
	os.Rename(tmp, dst)
}

// ── what WhatsApp says ────────────────────────────────────────────

func handle(evt any) {
	if syncing.Load() {
		syncDone.Add(1)
	}
	switch e := evt.(type) {
	case *events.OfflineSyncPreview:
		// A few is no catching up: they come as they always do.
		if e.Messages+e.Receipts+e.Notifications > 12 {
			syncTotal.Store(int64(e.Total))
			syncDone.Store(0)
			syncing.Store(true)
			run := syncRun.Add(1)
			emit(map[string]any{"t": "sync", "on": true, "done": 0, "total": e.Total})
			// Never longer than this, should the end not be said.
			go func() {
				time.Sleep(90 * time.Second)
				if syncRun.Load() == run && syncing.Load() {
					endSync()
				}
			}()
		}
	case *events.OfflineSyncCompleted:
		if syncing.Load() {
			endSync()
		}
	case *events.Connected:
		state("ok", "")
		lastChats = "" // sent again, now with the pictures it can ask for
		if cli.Store.PushName != "" {
			cli.SendPresence(ctx, types.PresenceUnavailable) // not "online" until the view is looked at
		}
		touch()
	case *events.PairSuccess:
		state("connecting", "Linked. Fetching your chats…")
	case *events.Disconnected:
		state("offline", "Reconnecting…")
	case *events.KeepAliveTimeout:
		state("offline", "Reconnecting…")
	case *events.StreamReplaced:
		state("offline", "WhatsApp is open somewhere else as this device")
	case *events.TemporaryBan:
		state("offline", "WhatsApp has paused this account: "+e.String())
	case *events.ClientOutdated:
		state("offline", "WhatsApp wants a newer version of this helper (rebuild it)")
	case *events.LoggedOut:
		db.Exec(`DELETE FROM msgs`)
		db.Exec(`DELETE FROM chats`)
		state("pair", "Unlinked from the phone")
		quit(0) // the island starts it again, with a fresh device
	case *events.Message:
		message(e, true)
	case *events.MediaRetry:
		go mediaRetried(e)
	case *events.HistorySync:
		history(e)
	case *events.Receipt:
		receipt(e)
	case *events.ChatPresence:
		jid := canon(e.Chat, e.SenderAlt).String()
		emit(map[string]any{"t": "typing", "jid": jid, "on": e.State == types.ChatPresenceComposing})
	case *events.Mute:
		chatFlag(e.JID, "muted", e.Action.GetMuted() && (e.Action.GetMuteEndTimestamp() <= 0 || e.Action.GetMuteEndTimestamp() > time.Now().UnixMilli()))
	case *events.Pin:
		chatFlag(e.JID, "pinned", e.Action.GetPinned())
	case *events.Archive:
		chatFlag(e.JID, "archived", e.Action.GetArchived())
	case *events.MarkChatAsRead:
		if e.Action.GetRead() {
			jid := canon(e.JID, types.EmptyJID).String()
			db.Exec(`UPDATE msgs SET seen = 1 WHERE chat = ? AND me = 0`, jid)
			db.Exec(`UPDATE chats SET unread = 0 WHERE jid = ?`, jid)
			touch()
		}
	case *events.Contact, *events.PushName, *events.GroupInfo, *events.JoinedGroup:
		names.Clear()
		if g, ok := evt.(*events.GroupInfo); ok && g.Name != nil {
			groupNames.Store(g.JID.String(), g.Name.Name)
			db.Exec(`UPDATE chats SET name = ? WHERE jid = ?`, g.Name.Name, g.JID.String())
		}
		touch()
	case *events.Picture:
		os.Remove(picPath(canon(e.JID, types.EmptyJID)))
		picMu.Lock()
		delete(picAsked, canon(e.JID, types.EmptyJID).String())
		picMu.Unlock()
		touch()
	}
}

func chatFlag(j types.JID, col string, v bool) {
	jid := canon(j, types.EmptyJID).String()
	db.Exec(`INSERT INTO chats (jid) VALUES (?) ON CONFLICT (jid) DO NOTHING`, jid)
	db.Exec(`UPDATE chats SET `+col+` = ? WHERE jid = ?`, b2i(v), jid)
	touch()
}

// A chat is known by the phone number where WhatsApp lets it be: a person can
// come as their number or as their LID (a hidden id), and both are one chat.
func canon(j, alt types.JID) types.JID {
	j = j.ToNonAD()
	if j.Server == types.HiddenUserServer {
		if !alt.IsEmpty() && alt.Server == types.DefaultUserServer {
			return alt.ToNonAD()
		}
		if cli != nil && cli.Store != nil && cli.Store.LIDs != nil {
			if pn, err := cli.Store.LIDs.GetPNForLID(ctx, j); err == nil && !pn.IsEmpty() {
				return pn.ToNonAD()
			}
		}
	}
	return j
}

func skipChat(j types.JID) bool {
	return j.Server == types.BroadcastServer || j.Server == types.NewsletterServer || j.IsEmpty()
}

func message(e *events.Message, live bool) {
	info := e.Info
	alt := info.SenderAlt
	if info.IsFromMe {
		alt = info.RecipientAlt
	}
	chat := canon(info.Chat, alt)
	if skipChat(chat) {
		return
	}
	jid := chat.String()
	m := e.Message
	if m == nil {
		return
	}
	// Deleted for everyone, or edited: the one already kept changes.
	if pm := m.GetProtocolMessage(); pm != nil {
		id := pm.GetKey().GetID()
		switch pm.GetType() {
		case waE2E.ProtocolMessage_REVOKE:
			db.Exec(`UPDATE msgs SET text = 'This message was deleted', kind = 'deleted', media = '', raw = NULL WHERE chat = ? AND id = ?`, jid, id)
		case waE2E.ProtocolMessage_MESSAGE_EDIT:
			if t, _ := describe(pm.GetEditedMessage()); t != "" {
				db.Exec(`UPDATE msgs SET text = ?, edited = 1 WHERE chat = ? AND id = ?`, t, jid, id)
			}
		default:
			return
		}
		if live {
			if r, ok := loadRow(jid, id); ok {
				emit(map[string]any{"t": "msg", "jid": jid, "live": false, "msg": r.json()})
			}
			touch()
		}
		return
	}
	// A reaction: kept beside the message it is on, which shows it.
	if rm := m.GetReactionMessage(); rm != nil {
		who := "me"
		if !info.IsFromMe {
			who = canon(info.Sender, info.SenderAlt).String()
		}
		target := rm.GetKey().GetID()
		keepReaction(jid, target, who, rm.GetText(), info.Timestamp.Unix())
		if live {
			changed(jid, target)
		}
		return
	}
	text, kind := describe(m)
	if kind == "" {
		return // a reaction, a key exchange, a poll vote…: nothing to show as a message
	}
	sender := canon(info.Sender, info.SenderAlt)
	r := row{
		Chat: jid, ID: info.ID, Sender: sender.String(), Me: info.IsFromMe, Text: text,
		TS: info.Timestamp.Unix(), Kind: kind, St: b2i(info.IsFromMe), Seen: info.IsFromMe || !live,
	}
	if info.IsGroup && !info.IsFromMe {
		r.SName = nameOf(sender, info.PushName)
	}
	r.QFrom, r.QText, r.QID = quoted(m)
	if img := m.GetImageMessage(); img != nil {
		r.W, r.H = int(img.GetWidth()), int(img.GetHeight())
		r.Media = thumb(info.ID, img.GetJPEGThumbnail())
	} else if v := m.GetVideoMessage(); v != nil {
		r.W, r.H = int(v.GetWidth()), int(v.GetHeight())
		r.Media = thumb(info.ID, v.GetJPEGThumbnail())
	} else if s := m.GetStickerMessage(); s != nil {
		r.W, r.H = int(s.GetWidth()), int(s.GetHeight())
	}
	var raw []byte
	if kind != "text" && kind != "deleted" && kind != "note" {
		raw, _ = proto.Marshal(m)
	}
	if e.IsEdit {
		db.Exec(`UPDATE msgs SET text = ?, edited = 1 WHERE chat = ? AND id = ?`, text, jid, info.ID)
	} else if !r.save(raw) {
		return // already kept (a history message heard twice)
	}

	name := ""
	if info.IsGroup {
		name = groupName(chat)
	} else if !info.IsFromMe {
		name = nameOf(sender, info.PushName)
	}
	if live {
		up := `INSERT INTO chats (jid, name, ts, grp, unread) VALUES (?, ?, ?, ?, ?)
			ON CONFLICT (jid) DO UPDATE SET ts = MAX(ts, excluded.ts), grp = excluded.grp,
			name = CASE WHEN excluded.name != '' THEN excluded.name ELSE name END,
			unread = CASE WHEN ? THEN 0 ELSE unread + excluded.unread END,
			archived = CASE WHEN muted = 0 THEN 0 ELSE archived END`
		db.Exec(up, jid, name, r.TS, b2i(info.IsGroup), b2i(!info.IsFromMe), info.IsFromMe)
		var muted int
		db.QueryRow(`SELECT muted FROM chats WHERE jid = ?`, jid).Scan(&muted)
		title := name
		if info.IsGroup && r.SName != "" {
			title = r.SName + " · " + name
		}
		touch()
		if syncing.Load() {
			return // kept; the island has it all at the end
		}
		emit(map[string]any{"t": "msg", "jid": jid, "name": title, "live": true, "muted": muted != 0, "msg": r.json()})
		// A sticker comes with no thumbnail, and a picture's is a blur: fetched at once (a video if it is small).
		if kind == "sticker" || kind == "image" || kind == "video" && smallVideo(jid, info.ID) {
			go fetchMedia(jid, info.ID)
		}
	}
}

// What a message says, in a line, and what kind it is ("" for nothing to show).
func describe(m *waE2E.Message) (string, string) {
	if m == nil {
		return "", ""
	}
	switch {
	case m.Conversation != nil:
		return m.GetConversation(), "text"
	case m.ExtendedTextMessage != nil:
		return m.GetExtendedTextMessage().GetText(), "text"
	case m.ImageMessage != nil:
		return m.GetImageMessage().GetCaption(), "image"
	case m.VideoMessage != nil:
		return m.GetVideoMessage().GetCaption(), "video"
	case m.AudioMessage != nil:
		a := m.GetAudioMessage()
		s := a.GetSeconds()
		label := "Audio"
		if a.GetPTT() {
			label = "Voice message"
		}
		return fmt.Sprintf("%s · %d:%02d", label, s/60, s%60), "audio"
	case m.StickerMessage != nil:
		return "Sticker", "sticker"
	case m.DocumentMessage != nil:
		d := m.GetDocumentMessage()
		name := d.GetFileName()
		if name == "" {
			name = d.GetTitle()
		}
		if c := d.GetCaption(); c != "" {
			name += "\n" + c
		}
		return name, "doc"
	case m.DocumentWithCaptionMessage != nil:
		return describe(m.GetDocumentWithCaptionMessage().GetMessage())
	case m.LocationMessage != nil:
		l := m.GetLocationMessage()
		if l.GetName() != "" {
			return "📍 " + l.GetName(), "note"
		}
		return "📍 Location", "note"
	case m.LiveLocationMessage != nil:
		return "📍 Live location", "note"
	case m.ContactMessage != nil:
		return "👤 " + m.GetContactMessage().GetDisplayName(), "note"
	case m.ContactsArrayMessage != nil:
		return "👤 Contacts", "note"
	case m.PollCreationMessage != nil:
		return "📊 " + m.GetPollCreationMessage().GetName(), "note"
	case m.PollCreationMessageV3 != nil:
		return "📊 " + m.GetPollCreationMessageV3().GetName(), "note"
	case m.ViewOnceMessage != nil:
		return describe(m.GetViewOnceMessage().GetMessage())
	case m.ViewOnceMessageV2 != nil:
		return "View once (open on your phone)", "note"
	case m.EphemeralMessage != nil:
		return describe(m.GetEphemeralMessage().GetMessage())
	}
	return "", ""
}

// What a message answers, if it is a reply: who said it ("You" for this account) and its first line.
func quoted(m *waE2E.Message) (string, string, string) {
	var ci *waE2E.ContextInfo
	switch {
	case m.ExtendedTextMessage != nil:
		ci = m.GetExtendedTextMessage().GetContextInfo()
	case m.ImageMessage != nil:
		ci = m.GetImageMessage().GetContextInfo()
	case m.VideoMessage != nil:
		ci = m.GetVideoMessage().GetContextInfo()
	case m.AudioMessage != nil:
		ci = m.GetAudioMessage().GetContextInfo()
	case m.DocumentMessage != nil:
		ci = m.GetDocumentMessage().GetContextInfo()
	case m.StickerMessage != nil:
		ci = m.GetStickerMessage().GetContextInfo()
	}
	if ci.GetQuotedMessage() == nil {
		return "", "", ""
	}
	qm := ci.GetQuotedMessage()
	text, kind := describe(qm)
	// A picture, video or sticker quoted: the small picture it carries, in case the message itself is not kept here.
	if id := ci.GetStanzaID(); id != "" && !exists(quotePath(id)) {
		var small []byte
		if im := qm.GetImageMessage(); im != nil {
			small = im.GetJPEGThumbnail()
		} else if v := qm.GetVideoMessage(); v != nil {
			small = v.GetJPEGThumbnail()
		} else if st := qm.GetStickerMessage(); st != nil {
			small = st.GetPngThumbnail()
		}
		if len(small) > 0 {
			os.WriteFile(quotePath(id), small, 0o600)
		}
	}
	who := ""
	if pj, err := types.ParseJID(ci.GetParticipant()); err == nil && !pj.IsEmpty() {
		own := cli.Store.ID != nil && pj.User == cli.Store.ID.User || !cli.Store.LID.IsEmpty() && pj.User == cli.Store.LID.User
		if own {
			who = "You"
		} else {
			who = listName(canon(pj, types.EmptyJID))
		}
	}
	return who, firstLine(text, kind), ci.GetStanzaID()
}

// A message in a line, for a quote: its first line, cut at 80 letters; a picture or file by what it is.
func firstLine(text, kind string) string {
	if i := strings.IndexByte(text, '\n'); i >= 0 {
		text = text[:i]
	}
	if r := []rune(text); len(r) > 80 {
		text = string(r[:79]) + "…"
	}
	if text == "" {
		text = map[string]string{"image": "📷 Photo", "video": "🎥 Video", "sticker": "Sticker", "audio": "🎤 Voice message", "doc": "📄 Document"}[kind]
	}
	return text
}

func thumb(id string, jpeg []byte) string {
	if len(jpeg) == 0 {
		return ""
	}
	path := filepath.Join(cacheDir, "media", safe(id)+"-t.jpg")
	if os.WriteFile(path, jpeg, 0o600) != nil {
		return ""
	}
	return path
}

func safe(s string) string {
	return strings.Map(func(r rune) rune {
		if r >= 'a' && r <= 'z' || r >= 'A' && r <= 'Z' || r >= '0' && r <= '9' || r == '-' || r == '_' {
			return r
		}
		return '_'
	}, s)
}

// The history the phone hands over when it is linked (and in pieces after).
func history(e *events.HistorySync) {
	for _, conv := range e.Data.GetConversations() {
		j, err := types.ParseJID(conv.GetID())
		if err != nil {
			continue
		}
		chat := canon(j, types.EmptyJID)
		if pn := conv.GetPnJID(); pn != "" && chat.Server == types.HiddenUserServer {
			if p, err := types.ParseJID(pn); err == nil {
				chat = p.ToNonAD()
			}
		}
		if skipChat(chat) {
			continue
		}
		jid := chat.String()
		name := conv.GetName()
		if name == "" {
			name = conv.GetDisplayName()
		}
		db.Exec(`INSERT INTO chats (jid, name, ts, grp, unread, pinned, archived) VALUES (?, ?, ?, ?, ?, ?, ?)
			ON CONFLICT (jid) DO UPDATE SET ts = MAX(ts, excluded.ts), unread = excluded.unread,
			name = CASE WHEN excluded.name != '' THEN excluded.name ELSE name END,
			pinned = MAX(pinned, excluded.pinned), archived = MAX(archived, excluded.archived)`,
			jid, name, convTime(conv.GetLastMsgTimestamp(), conv.GetConversationTimestamp()), b2i(chat.Server == types.GroupServer),
			conv.GetUnreadCount(), b2i(conv.GetPinned() > 0), b2i(conv.GetArchived()))
		unread := int(conv.GetUnreadCount())
		msgs := conv.GetMessages()
		for i, hm := range msgs {
			wm := hm.GetMessage()
			if wm == nil {
				continue
			}
			ev, err := cli.ParseWebMessage(j, wm)
			if err != nil {
				continue
			}
			message(ev, false)
			// History comes newest first: the newest `unread` ones from others are not seen yet.
			if i < unread && !ev.Info.IsFromMe {
				db.Exec(`UPDATE msgs SET seen = 0 WHERE chat = ? AND id = ?`, jid, ev.Info.ID)
			}
			if ev.Info.IsFromMe {
				db.Exec(`UPDATE msgs SET st = MAX(st, 3) WHERE chat = ? AND id = ?`, jid, ev.Info.ID)
			}
		}
		db.Exec(`UPDATE chats SET ts = MAX(ts, COALESCE((SELECT MAX(ts) FROM msgs WHERE chat = ?), 0)) WHERE jid = ?`, jid, jid)
	}
	touch()
}

// Ticks on what was sent: 1 sent · 2 delivered · 3 read.
func receipt(e *events.Receipt) {
	st := 0
	switch e.Type {
	case types.ReceiptTypeDelivered:
		st = 2
	case types.ReceiptTypeRead, types.ReceiptTypePlayed:
		st = 3
	case types.ReceiptTypeReadSelf:
		// Read on another of this account's devices: no longer unread here.
		jid := canon(e.Chat, e.SenderAlt).String()
		for _, id := range e.MessageIDs {
			db.Exec(`UPDATE msgs SET seen = 1 WHERE chat = ? AND id = ?`, jid, id)
		}
		db.Exec(`UPDATE chats SET unread = (SELECT COUNT(*) FROM msgs WHERE chat = ? AND me = 0 AND seen = 0) WHERE jid = ?`, jid, jid)
		touch()
		return
	default:
		return
	}
	if e.IsFromMe {
		return
	}
	jid := canon(e.Chat, e.SenderAlt).String()
	for _, id := range e.MessageIDs {
		db.Exec(`UPDATE msgs SET st = MAX(st, ?) WHERE chat = ? AND id = ? AND me = 1`, st, jid, id)
		if syncing.Load() {
			continue
		}
		if r, ok := loadRow(jid, id); ok {
			emit(map[string]any{"t": "msg", "jid": jid, "live": false, "msg": r.json()})
		}
	}
}

// ── names and faces ───────────────────────────────────────────────

var names sync.Map // jid → the name the chat list shows

// A person's name for the chat list, remembered (asked of the store once).
func listName(j types.JID) string {
	if n, ok := names.Load(j.String()); ok {
		return n.(string)
	}
	n := nameOf(j, "")
	names.Store(j.String(), n)
	return n
}

func nameOf(j types.JID, push string) string {
	if c, err := cli.Store.Contacts.GetContact(ctx, j); err == nil {
		for _, n := range []string{c.FullName, c.FirstName, c.BusinessName, c.PushName} {
			if n != "" {
				return n
			}
		}
	}
	if j.Server == types.DefaultUserServer {
		if lid, err := cli.Store.LIDs.GetLIDForPN(ctx, j); err == nil && !lid.IsEmpty() {
			if c, err := cli.Store.Contacts.GetContact(ctx, lid); err == nil {
				for _, n := range []string{c.FullName, c.FirstName, c.BusinessName, c.PushName} {
					if n != "" {
						return n
					}
				}
			}
		}
	}
	if push != "" {
		return push
	}
	if j.Server == types.DefaultUserServer {
		return "+" + j.User
	}
	return j.User
}

func groupName(j types.JID) string {
	if n, ok := groupNames.Load(j.String()); ok {
		return n.(string)
	}
	var name string
	db.QueryRow(`SELECT name FROM chats WHERE jid = ?`, j.String()).Scan(&name)
	if name == "" && cli.IsConnected() {
		if gi, err := cli.GetGroupInfo(ctx, j); err == nil {
			name = gi.Name
		}
	}
	if name != "" {
		groupNames.Store(j.String(), name)
	}
	return name
}

func picPath(j types.JID) string { return filepath.Join(cacheDir, "media", "pp-"+safe(j.User)+".jpg") }

// The chat's picture, if it has one: fetched once, kept a week ("none" kept a day:
// people add one, and a refusal may be WhatsApp's mood of the moment).
func picture(j types.JID) string {
	path := picPath(j)
	if st, err := os.Stat(path); err == nil {
		age := time.Since(st.ModTime())
		if st.Size() == 0 && age < 24*time.Hour {
			return "" // has none
		}
		if st.Size() > 0 && age < 7*24*time.Hour {
			return path
		}
	}
	// Asked only once connected, and once a run: asked before (the list is sent before it
	// connects) every chat was marked asked and none was ever fetched.
	if !cli.IsConnected() {
		return ""
	}
	picMu.Lock()
	asked := picAsked[j.String()]
	picAsked[j.String()] = true
	picMu.Unlock()
	if !asked {
		go fetchPicture(j, path)
	}
	if st, err := os.Stat(path); err == nil && st.Size() > 0 {
		return path
	}
	return ""
}

func fetchPicture(j types.JID, path string) {
	picSlots <- struct{}{}
	defer func() { <-picSlots }()
	again := func() {
		picMu.Lock()
		delete(picAsked, j.String()) // asked again with the next list
		picMu.Unlock()
	}
	info, err := cli.GetProfilePictureInfo(ctx, j, &whatsmeow.GetProfilePictureParams{Preview: true})
	// A person by their number may be refused where their LID is not (WhatsApp moves people to LIDs).
	if (err != nil || info == nil) && j.Server == types.DefaultUserServer {
		if lid, lerr := cli.Store.LIDs.GetLIDForPN(ctx, j); lerr == nil && !lid.IsEmpty() {
			if li, lerr := cli.GetProfilePictureInfo(ctx, lid, &whatsmeow.GetProfilePictureParams{Preview: true}); lerr == nil && li != nil {
				info, err = li, nil
			}
		}
	}
	if err != nil || info == nil || info.URL == "" {
		if err == nil || errors.Is(err, whatsmeow.ErrProfilePictureNotSet) || errors.Is(err, whatsmeow.ErrProfilePictureUnauthorized) {
			os.WriteFile(path, nil, 0o600)
		} else {
			fmt.Fprintf(os.Stderr, "lumen-wa picture of %s: %v\n", j.Server, err)
			again()
		}
		return
	}
	resp, err := http.Get(info.URL)
	if err != nil {
		again()
		return
	}
	defer resp.Body.Close()
	data, err := io.ReadAll(io.LimitReader(resp.Body, 2<<20))
	if err != nil || resp.StatusCode != 200 || len(data) == 0 {
		fmt.Fprintf(os.Stderr, "lumen-wa picture of %s: HTTP %d\n", j.Server, resp.StatusCode)
		again()
		return
	}
	if os.WriteFile(path, data, 0o600) == nil {
		touch()
	}
}

// ── what goes back ────────────────────────────────────────────────

type row struct {
	Chat, ID, Sender, SName string
	Me                      bool
	Text                    string
	TS                      int64
	Kind, Media             string
	W, H, St                int
	Seen                    bool
	QFrom, QText, QID       string
	Edited                  bool
}

func (r row) save(raw []byte) bool {
	res, err := db.Exec(`INSERT OR IGNORE INTO msgs (chat, id, sender, sname, me, text, ts, kind, media, w, h, st, seen, raw, qfrom, qtext, qid)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		r.Chat, r.ID, r.Sender, r.SName, b2i(r.Me), r.Text, r.TS, r.Kind, r.Media, r.W, r.H, r.St, b2i(r.Seen), raw, r.QFrom, r.QText, r.QID)
	if err != nil {
		return false
	}
	n, _ := res.RowsAffected()
	return n > 0
}

func (r row) json() map[string]any {
	react, mine := reactionsOf(r.Chat, r.ID)
	return map[string]any{"id": r.ID, "me": r.Me, "from": r.SName, "text": r.Text, "ts": r.TS,
		"kind": r.Kind, "media": r.Media, "w": r.W, "h": r.H, "st": r.St, "qfrom": r.QFrom, "qtext": r.QText,
		"react": react, "mine": mine, "edited": r.Edited, "pic": r.pic(), "file": r.file(), "qpic": r.qpic()}
}

// What the chat draws for it: a picture's or video's preview once there is one,
// else WhatsApp's small one; a sticker is its own file (small, and it may move).
func (r row) pic() string {
	switch r.Kind {
	case "sticker":
		return r.Media
	case "image", "video":
		if p := previewPath(r.ID); exists(p) {
			return p
		}
		if p := filepath.Join(cacheDir, "media", safe(r.ID)+"-t.jpg"); exists(p) {
			return p
		}
	}
	return ""
}

// The whole file, once it is here.
func (r row) file() string {
	if whole(r.Media) {
		return r.Media
	}
	return ""
}

// The picture of the message it answers, small: that message's own, or the one the quote carried.
func (r row) qpic() string {
	if r.QID == "" {
		r.QID = guessQuoted(r)
	}
	if r.QID == "" {
		return ""
	}
	src := ""
	if q, ok := loadRow(r.Chat, r.QID); ok && q.Kind != "deleted" {
		src = q.pic()
	}
	if p := quotePath(r.QID); src == "" && exists(p) {
		src = p
	}
	if src == "" {
		return ""
	}
	return squared(r.QID, src)
}

// A picture cut to its middle square, small: what a quote shows, filled to its rounded corners.
func squared(id, src string) string {
	dst := filepath.Join(cacheDir, "media", safe(id)+"-s.jpg")
	if exists(dst) {
		return dst
	}
	tmp := dst + ".part.jpg"
	if exec.Command("ffmpeg", "-v", "error", "-y", "-i", src, "-frames:v", "1", "-vf", "crop='min(iw,ih)':'min(iw,ih)',scale=96:96", "-q:v", "4", tmp).Run() != nil {
		os.Remove(tmp)
		return src
	}
	os.Rename(tmp, dst)
	return dst
}

// A reply kept before replies kept what they answer (qid), quoting a picture or video: the
// latest one that person sent in the chat before it is taken as the one (noted, so once).
func guessQuoted(r row) string {
	if r.QText == "" || !(strings.HasPrefix(r.QText, "📷") || strings.HasPrefix(r.QText, "🎥") || r.QText == "Sticker") {
		return ""
	}
	who := `me = 0`
	args := []any{r.Chat, r.TS}
	if r.QFrom == "You" {
		who = `me = 1`
	} else if strings.HasSuffix(r.Chat, "@g.us") {
		who = `me = 0 AND sname = ?`
		args = append(args, r.QFrom)
	}
	var id string
	if db.QueryRow(`SELECT id FROM msgs WHERE chat = ? AND ts <= ? AND kind IN ('image', 'video', 'sticker') AND `+who+`
		ORDER BY ts DESC, rowid DESC LIMIT 1`, args...).Scan(&id) != nil {
		return ""
	}
	db.Exec(`UPDATE msgs SET qid = ? WHERE chat = ? AND id = ?`, id, r.Chat, r.ID)
	return id
}

func quotePath(id string) string { return filepath.Join(cacheDir, "media", safe(id)+"-q.jpg") }

func exists(path string) bool {
	_, err := os.Stat(path)
	return err == nil
}

const rowCols = `chat, id, sender, sname, me, text, ts, kind, media, w, h, st, seen, qfrom, qtext, edited, qid`

func scanRow(s interface{ Scan(...any) error }) (row, error) {
	var r row
	var me, seen, edited int
	err := s.Scan(&r.Chat, &r.ID, &r.Sender, &r.SName, &me, &r.Text, &r.TS, &r.Kind, &r.Media, &r.W, &r.H, &r.St, &seen, &r.QFrom, &r.QText, &edited, &r.QID)
	r.Me, r.Seen, r.Edited = me != 0, seen != 0, edited != 0
	return r, err
}

func loadRow(jid, id string) (row, bool) {
	r, err := scanRow(db.QueryRow(`SELECT `+rowCols+` FROM msgs WHERE chat = ? AND id = ?`, jid, id))
	return r, err == nil
}

// Messages, oldest first, newest-first from the query.
func queryMsgs(q string, args ...any) []map[string]any {
	list := []map[string]any{}
	rows, err := db.Query(q, args...)
	if err != nil {
		return list
	}
	// Read whole before each becomes JSON: that asks for its reactions, and the store has one connection.
	var got []row
	for rows.Next() {
		if r, err := scanRow(rows); err == nil {
			got = append(got, r)
		}
	}
	rows.Close()
	for _, r := range got {
		list = append(list, r.json())
	}
	for i, k := 0, len(list)-1; i < k; i, k = i+1, k-1 {
		list[i], list[k] = list[k], list[i]
	}
	return list
}

// The 60 before a message (by id): scrolling up through a chat.
func sendOlder(jid, before string) {
	list := queryMsgs(`SELECT `+rowCols+` FROM msgs WHERE chat = ? AND (ts, rowid) <
		(SELECT ts, rowid FROM msgs WHERE chat = ? AND id = ?) ORDER BY ts DESC, rowid DESC LIMIT 60`, jid, jid, before)
	emit(map[string]any{"t": "older", "jid": jid, "msgs": list})
	go fetchPictures(jid, list, len(list))
}

func sendMsgs(jid string) {
	list := queryMsgs(`SELECT `+rowCols+` FROM msgs WHERE chat = ? ORDER BY ts DESC, rowid DESC LIMIT 60`, jid)
	emit(map[string]any{"t": "msgs", "jid": jid, "msgs": list})
	go fetchPictures(jid, list, 16)
}

// The newest `n` pictures, videos and stickers of a list (oldest first) that have
// no preview yet, whole, one at a time: the thumbnail WhatsApp sends is a blur.
// A video only when it is small (most are): a long one waits to be played.
func fetchPictures(jid string, list []map[string]any, n int) {
	for i := len(list) - 1; i >= 0 && n > 0; i-- {
		m := list[i]
		kind, _ := m["kind"].(string)
		id, _ := m["id"].(string)
		pic, _ := m["pic"].(string)
		switch kind {
		case "image", "video":
			n--
			if pic == previewPath(id) {
				continue
			}
			if kind == "video" && !smallVideo(jid, id) {
				continue
			}
		case "sticker":
			n--
			if pic != "" {
				continue
			}
		default:
			continue
		}
		fetchMedia(jid, id)
	}
}

// A video worth fetching before it is asked for: 16 MB at most.
func smallVideo(jid, id string) bool {
	var raw []byte
	if db.QueryRow(`SELECT raw FROM msgs WHERE chat = ? AND id = ?`, jid, id).Scan(&raw) != nil {
		return false
	}
	var m waE2E.Message
	if proto.Unmarshal(raw, &m) != nil {
		return false
	}
	size := m.GetVideoMessage().GetFileLength()
	return size > 0 && size <= 16<<20
}

// Caught up: the list once, and the island reloads the chat it shows.
func endSync() {
	syncing.Store(false)
	emit(map[string]any{"t": "sync", "on": false, "done": syncDone.Load(), "total": syncTotal.Load()})
	lastChats = ""
	sendChats()
}

func touch() {
	dirtyMu.Lock()
	dirty = true
	dirtyMu.Unlock()
}

func flusher() {
	n := 0
	for range time.Tick(125 * time.Millisecond) {
		// Catching up: how far, eight times a second; the list waits for the end.
		if syncing.Load() {
			emit(map[string]any{"t": "sync", "on": true, "done": syncDone.Load(), "total": syncTotal.Load()})
			continue
		}
		if n++; n%3 != 0 {
			continue
		}
		dirtyMu.Lock()
		d := dirty
		dirty = false
		dirtyMu.Unlock()
		if d {
			sendChats()
		}
	}
}

var chatsMu sync.Mutex

func sendChats() {
	chatsMu.Lock()
	defer chatsMu.Unlock()
	rows, err := db.Query(`SELECT c.jid, c.name, c.unread, c.ts, c.grp, c.muted, c.pinned,
			COALESCE((SELECT m.text || char(31) || m.me || char(31) || m.sname || char(31) || m.kind FROM msgs m
				WHERE m.chat = c.jid ORDER BY m.ts DESC, m.rowid DESC LIMIT 1), '')
		FROM chats c WHERE c.archived = 0 AND c.ts > 0 ORDER BY c.pinned DESC, c.ts DESC LIMIT 60`)
	if err != nil {
		return
	}
	type chat struct {
		jid, name, last             string
		unread, ts, grp, muted, pin int64
	}
	var list []chat
	for rows.Next() {
		var c chat
		rows.Scan(&c.jid, &c.name, &c.unread, &c.ts, &c.grp, &c.muted, &c.pin, &c.last)
		list = append(list, c)
	}
	rows.Close()
	total := 0
	var outList []map[string]any
	for i, c := range list {
		j, _ := types.ParseJID(c.jid)
		name := c.name
		if c.grp == 0 && cli != nil && cli.Store.ID != nil {
			if n := listName(j); n != "" && !(strings.HasPrefix(n, "+") && name != "") {
				name = n
			}
		}
		if name == "" {
			name = "+" + j.User
		}
		last := ""
		if p := strings.Split(c.last, "\x1f"); len(p) == 4 {
			last = strings.ReplaceAll(p[0], "\n", " ")
			if last == "" {
				last = map[string]string{"image": "📷 Photo", "video": "🎥 Video", "sticker": "Sticker"}[p[3]]
			} else if p[3] == "image" {
				last = "📷 " + last
			} else if p[3] == "video" {
				last = "🎥 " + last
			} else if p[3] == "audio" {
				last = "🎤 " + last
			} else if p[3] == "doc" {
				last = "📄 " + last
			}
			if p[1] == "1" {
				last = "You: " + last
			} else if c.grp == 1 && p[2] != "" {
				last = strings.SplitN(p[2], " ", 2)[0] + ": " + last
			}
		}
		pic := ""
		if cli != nil && cli.Store.ID != nil && i < 60 {
			pic = picture(j)
		}
		if c.muted == 0 {
			total += int(c.unread)
		}
		outList = append(outList, map[string]any{"jid": c.jid, "name": name, "last": last, "ts": c.ts,
			"unread": c.unread, "group": c.grp == 1, "muted": c.muted == 1, "pinned": c.pin == 1, "pic": pic})
	}
	if outList == nil {
		outList = []map[string]any{}
	}
	b, _ := json.Marshal(map[string]any{"t": "chats", "unread": total, "chats": outList})
	if string(b) == lastChats {
		return
	}
	lastChats = string(b)
	outMu.Lock()
	out.Write(b)
	out.WriteByte('\n')
	out.Flush()
	outMu.Unlock()
}

var lastChats string // what was sent last: the same list is not sent again

// When a chat last moved: its last message, or (WhatsApp often leaves that out)
// when the conversation itself last changed.
func convTime(last, conv uint64) int64 {
	if last > 0 {
		return int64(last)
	}
	return int64(conv)
}

func b2i(b bool) int {
	if b {
		return 1
	}
	return 0
}
