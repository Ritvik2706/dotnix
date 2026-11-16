package main

// Link previews: what a message with a link shows of where it goes, as WhatsApp's card does — a
// picture, a title, a line of description and the site. Most messages bring their own (the phone
// that sent it made one: ExtendedTextMessage's Title, Description, JPEGThumbnail); those that don't
// (sent from here, from a client that didn't, or whose preview was left out) have one made here
// from the page's own tags (og:/twitter:/<title>), in the background, and told as {"t":"linkpv"}.
//
// Kept per message in media/<id>-l.json (+ <id>-l.jpg), and per address in media/link-<hash>.json, so
// a page is fetched once however many messages carry it, and a page that had nothing is not asked
// again (its file says so).

import (
	"context"
	"crypto/sha1"
	"encoding/hex"
	"encoding/json"
	"html"
	"image"
	_ "image/jpeg"
	"io"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"time"

	"go.mau.fi/whatsmeow/proto/waE2E"
	"google.golang.org/protobuf/proto"
)

type linkPreview struct {
	URL   string `json:"url"`
	Title string `json:"title"`
	Desc  string `json:"desc"`
	Site  string `json:"site"`
	Pic   string `json:"pic"`
	W     int    `json:"w"` // the picture's size: a wide one is a banner over the card, else a square beside it
	H     int    `json:"h"`
	None  bool   `json:"none,omitempty"` // looked for, and there was nothing to show
	Hi    bool   `json:"hi,omitempty"`   // its picture is the sender's full one (not the small one inside the message)
}

var (
	urlRe      = regexp.MustCompile(`(?i)\bhttps?://[^\s<>"']+`)
	linkFetch  sync.Map                       // id → being fetched
	linkSlots  = make(chan struct{}, 3)       // pages fetched at once
	linkClient = &http.Client{Timeout: 8 * time.Second}
)

// The first link in a text, without the punctuation that ends a sentence after it.
func firstURL(text string) string {
	u := urlRe.FindString(text)
	return strings.TrimRight(u, ".,;:!?)]}'\"…")
}

func siteOf(u string) string {
	p, err := url.Parse(u)
	if err != nil {
		return ""
	}
	return strings.TrimPrefix(strings.ToLower(p.Hostname()), "www.")
}

func linkFile(id string) string { return filepath.Join(cacheDir, "media", safe(id)+"-l.json") }

func readPreview(path string) (linkPreview, bool) {
	var p linkPreview
	b, err := os.ReadFile(path)
	if err != nil || json.Unmarshal(b, &p) != nil {
		return p, false
	}
	return p, true
}

func writePreview(path string, p linkPreview) {
	if b, err := json.Marshal(p); err == nil {
		os.WriteFile(path, b, 0o600)
	}
}

// What a row shows of its link: the card when it is known (ok), else at least where it goes —
// and then one is being made, and comes as "linkpv".
func previewOf(r row) (linkPreview, bool) {
	if r.Kind != "text" {
		return linkPreview{}, false
	}
	u := firstURL(r.Text)
	if u == "" {
		return linkPreview{}, false
	}
	if p, ok := readPreview(linkFile(r.ID)); ok {
		return p, !p.None
	}
	// The one it came with.
	var raw []byte
	db.QueryRow(`SELECT raw FROM msgs WHERE chat = ? AND id = ?`, r.Chat, r.ID).Scan(&raw)
	msg := &waE2E.Message{}
	if len(raw) > 0 && proto.Unmarshal(raw, msg) == nil {
		if ext := msg.GetExtendedTextMessage(); ext != nil && (ext.GetTitle() != "" || len(ext.GetJPEGThumbnail()) > 0) {
			p := linkPreview{URL: u, Title: ext.GetTitle(), Desc: ext.GetDescription()}
			if c := ext.GetMatchedText(); strings.HasPrefix(c, "http") {
				p.URL = c
			}
			p.Site = siteOf(p.URL)
			if jpg := ext.GetJPEGThumbnail(); len(jpg) > 0 {
				path := filepath.Join(cacheDir, "media", safe(r.ID)+"-l.jpg")
				if os.WriteFile(path, jpg, 0o600) == nil {
					p.Pic = path
					p.W, p.H = picSize(path)
				}
			}
			writePreview(linkFile(r.ID), p)
			// The sender's full picture, when it was uploaded: the one inside is a small, soft one.
			if ext.GetThumbnailDirectPath() != "" {
				go fullPicture(r.Chat, r.ID, ext, p)
			}
			return p, true
		}
	}
	// None: made here, from the page.
	if _, busy := linkFetch.LoadOrStore(r.ID, true); !busy {
		go func(chat, id, u string) {
			defer linkFetch.Delete(id)
			p, final := pagePreview(u)
			if !final {
				return // the page couldn't be reached: asked again next time it is shown
			}
			writePreview(linkFile(id), p)
			if !p.None {
				emit(map[string]any{"t": "linkpv", "jid": chat, "id": id, "lurl": p.URL, "ltitle": p.Title, "ldesc": p.Desc, "lsite": p.Site, "lpic": p.Pic, "lw": p.W, "lh": p.H})
			}
		}(r.Chat, r.ID, u)
	}
	return linkPreview{URL: u, Site: siteOf(u)}, false
}

var (
	metaRe  = regexp.MustCompile(`(?is)<meta\s[^>]*>`)
	attrRe  = regexp.MustCompile(`(?is)([a-z:_-]+)\s*=\s*("([^"]*)"|'([^']*)')`)
	titleRe = regexp.MustCompile(`(?is)<title[^>]*>(.*?)</title>`)
)

// A page's card, from its tags: fetched once per address (kept by its hash), its picture made a
// JPEG at most 640 wide by ffmpeg (which reads WebP too). Not final when the page couldn't be
// reached at all (offline, a timeout): nothing is kept then, so it is tried again.
func pagePreview(u string) (linkPreview, bool) {
	sum := sha1.Sum([]byte(u))
	key := hex.EncodeToString(sum[:8])
	keep := filepath.Join(cacheDir, "media", "link-"+key+".json")
	if p, ok := readPreview(keep); ok {
		return p, true
	}
	linkSlots <- struct{}{}
	defer func() { <-linkSlots }()
	p := linkPreview{URL: u, Site: siteOf(u), None: true}
	req, err := http.NewRequest("GET", u, nil)
	if err != nil {
		writePreview(keep, p)
		return p, true
	}
	// The name sites give their cards to (many give a bare page to anything else).
	req.Header.Set("User-Agent", "WhatsApp/2.24 facebookexternalhit/1.1")
	req.Header.Set("Accept", "text/html,application/xhtml+xml")
	resp, err := linkClient.Do(req)
	if err != nil {
		return p, false
	}
	defer resp.Body.Close()
	if resp.StatusCode >= 400 || !strings.Contains(strings.ToLower(resp.Header.Get("Content-Type")), "html") {
		writePreview(keep, p)
		return p, true
	}
	body, _ := io.ReadAll(io.LimitReader(resp.Body, 768<<10))
	page := string(body)
	if i := strings.Index(strings.ToLower(page), "</head>"); i > 0 {
		page = page[:i]
	}
	tags := map[string]string{}
	for _, m := range metaRe.FindAllString(page, -1) {
		a := map[string]string{}
		for _, kv := range attrRe.FindAllStringSubmatch(m, -1) {
			a[strings.ToLower(kv[1])] = kv[3] + kv[4]
		}
		name := strings.ToLower(a["property"] + a["name"])
		if name != "" && a["content"] != "" {
			if _, seen := tags[name]; !seen {
				tags[name] = html.UnescapeString(strings.TrimSpace(a["content"]))
			}
		}
	}
	pick := func(keys ...string) string {
		for _, k := range keys {
			if v := tags[k]; v != "" {
				return v
			}
		}
		return ""
	}
	p.Title = pick("og:title", "twitter:title")
	if p.Title == "" {
		if m := titleRe.FindStringSubmatch(page); m != nil {
			p.Title = html.UnescapeString(strings.Join(strings.Fields(m[1]), " "))
		}
	}
	p.Desc = pick("og:description", "twitter:description", "description")
	if s := pick("og:site_name"); s != "" {
		p.Site = s
	}
	if img := pick("og:image", "og:image:url", "twitter:image", "twitter:image:src"); img != "" {
		if base, err := url.Parse(resp.Request.URL.String()); err == nil {
			if ref, err := base.Parse(img); err == nil {
				p.Pic = pageImage(ref.String(), key)
			}
		}
	}
	if p.Pic != "" {
		p.W, p.H = picSize(p.Pic)
	}
	p.None = p.Title == "" && p.Pic == ""
	writePreview(keep, p)
	return p, true
}

func picSize(path string) (int, int) {
	f, err := os.Open(path)
	if err != nil {
		return 0, 0
	}
	defer f.Close()
	c, _, err := image.DecodeConfig(f)
	if err != nil {
		return 0, 0
	}
	return c.Width, c.Height
}

func pageImage(u, key string) string {
	req, err := http.NewRequest("GET", u, nil)
	if err != nil {
		return ""
	}
	req.Header.Set("User-Agent", "WhatsApp/2.24 facebookexternalhit/1.1")
	resp, err := linkClient.Do(req)
	if err != nil {
		return ""
	}
	defer resp.Body.Close()
	if resp.StatusCode >= 400 {
		return ""
	}
	tmp := filepath.Join(cacheDir, "media", "link-"+key+".src")
	f, err := os.Create(tmp)
	if err != nil {
		return ""
	}
	_, err = io.Copy(f, io.LimitReader(resp.Body, 6<<20))
	f.Close()
	defer os.Remove(tmp)
	if err != nil {
		return ""
	}
	out := filepath.Join(cacheDir, "media", "link-"+key+".jpg")
	if exec.Command("ffmpeg", "-v", "error", "-y", "-i", tmp, "-frames:v", "1", "-vf", "scale='min(640,iw)':-2", "-q:v", "4", out).Run() != nil {
		return ""
	}
	return out
}

func fullPicture(chat, id string, ext *waE2E.ExtendedTextMessage, p linkPreview) {
	if _, busy := linkFetch.LoadOrStore(id, true); busy {
		return
	}
	defer linkFetch.Delete(id)
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	data, err := cli.DownloadThumbnail(ctx, ext)
	if err != nil || len(data) == 0 {
		return
	}
	path := filepath.Join(cacheDir, "media", safe(id)+"-L.jpg") // a new name: the small one stays drawn until this is
	if os.WriteFile(path, data, 0o600) != nil {
		return
	}
	p.Pic, p.Hi = path, true
	p.W, p.H = picSize(path)
	writePreview(linkFile(id), p)
	emit(map[string]any{"t": "linkpv", "jid": chat, "id": id, "lurl": p.URL, "ltitle": p.Title, "ldesc": p.Desc, "lsite": p.Site, "lpic": p.Pic, "lw": p.W, "lh": p.H})
}
