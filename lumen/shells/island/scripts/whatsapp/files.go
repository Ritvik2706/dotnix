// Sending a file: a picture, a video, a voice note or song, or anything else as
// a document. What the island pastes (a picture on the clipboard, saved to a
// file first) and what is dropped on the chat both come here.

package main

import (
	"bytes"
	"context"
	"fmt"
	"image"
	_ "image/gif"
	"image/jpeg"
	_ "image/png"
	"mime"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	"go.mau.fi/whatsmeow"
	"go.mau.fi/whatsmeow/proto/waE2E"
	"go.mau.fi/whatsmeow/types"
	"google.golang.org/protobuf/proto"
)

// What a file is sent as: "image", "video", "audio" or "doc", and its MIME type.
func kindOf(path string, data []byte) (string, string) {
	mt := mime.TypeByExtension(strings.ToLower(filepath.Ext(path)))
	if mt == "" {
		mt = http.DetectContentType(data)
	}
	mt = strings.TrimSpace(strings.SplitN(mt, ";", 2)[0])
	switch {
	case mt == "image/jpeg" || mt == "image/png" || mt == "image/gif" && !animated(data):
		return "image", mt
	case mt == "video/mp4":
		return "video", mt
	case mt == "audio/ogg" || mt == "audio/mpeg" || mt == "audio/mp4" || mt == "audio/aac":
		return "audio", mt
	}
	if mt == "" {
		mt = "application/octet-stream"
	}
	return "doc", mt
}

// A GIF of more than one frame stays a file (WhatsApp would show its first frame only).
func animated(data []byte) bool {
	return bytes.Count(data, []byte{0x21, 0xF9, 0x04}) > 1
}

// A picture as WhatsApp wants it: a JPEG (a PNG or a GIF is turned into one), its
// size, and a small JPEG to show before it is downloaded.
func asJPEG(data []byte) ([]byte, []byte, int, int, error) {
	img, format, err := image.Decode(bytes.NewReader(data))
	if err != nil {
		return nil, nil, 0, 0, err
	}
	b := img.Bounds()
	if format != "jpeg" {
		var buf bytes.Buffer
		if err := jpeg.Encode(&buf, flatten(img), &jpeg.Options{Quality: 92}); err != nil {
			return nil, nil, 0, 0, err
		}
		data = buf.Bytes()
	}
	var small bytes.Buffer
	jpeg.Encode(&small, shrink(img, 72), &jpeg.Options{Quality: 70})
	return data, small.Bytes(), b.Dx(), b.Dy(), nil
}

// On white, what was see-through (a JPEG has no transparency, and black would show).
func flatten(img image.Image) image.Image {
	b := img.Bounds()
	out := image.NewRGBA(image.Rect(0, 0, b.Dx(), b.Dy()))
	for y := 0; y < b.Dy(); y++ {
		for x := 0; x < b.Dx(); x++ {
			r, g, bl, a := img.At(b.Min.X+x, b.Min.Y+y).RGBA()
			w := 0xffff - a
			i := out.PixOffset(x, y)
			out.Pix[i] = uint8((r + w) >> 8)
			out.Pix[i+1] = uint8((g + w) >> 8)
			out.Pix[i+2] = uint8((bl + w) >> 8)
			out.Pix[i+3] = 0xff
		}
	}
	return out
}

// The picture at most `side` pixels on its longer side, each pixel the average of what it covers.
func shrink(img image.Image, side int) image.Image {
	b := img.Bounds()
	w, h := b.Dx(), b.Dy()
	if w == 0 || h == 0 {
		return img
	}
	s := float64(side) / float64(max(w, h))
	if s > 1 {
		s = 1
	}
	tw, th := max(1, int(float64(w)*s)), max(1, int(float64(h)*s))
	out := image.NewRGBA(image.Rect(0, 0, tw, th))
	for ty := 0; ty < th; ty++ {
		y0, y1 := ty*h/th, max(ty*h/th+1, (ty+1)*h/th)
		for tx := 0; tx < tw; tx++ {
			x0, x1 := tx*w/tw, max(tx*w/tw+1, (tx+1)*w/tw)
			var r, g, bl, n uint64
			for y := y0; y < y1; y += max(1, (y1-y0)/4) {
				for x := x0; x < x1; x += max(1, (x1-x0)/4) {
					cr, cg, cb, ca := img.At(b.Min.X+x, b.Min.Y+y).RGBA()
					wt := uint64(0xffff - ca)
					r, g, bl, n = r+uint64(cr)+wt, g+uint64(cg)+wt, bl+uint64(cb)+wt, n+1
				}
			}
			i := out.PixOffset(tx, ty)
			out.Pix[i], out.Pix[i+1], out.Pix[i+2], out.Pix[i+3] = uint8(r/n>>8), uint8(g/n>>8), uint8(bl/n>>8), 0xff
		}
	}
	return out
}

// A video's first frame, small, and its size (ffmpeg and ffprobe, if they are there).
func videoThumb(path string) ([]byte, int, int, uint32) {
	var w, h int
	var secs float64
	if out, err := exec.Command("ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries", "stream=width,height:format=duration",
		"-of", "default=nw=1:nk=1", path).Output(); err == nil {
		fmt.Sscan(string(out), &w, &h, &secs)
	}
	thumb, _ := exec.Command("ffmpeg", "-v", "error", "-i", path, "-frames:v", "1", "-vf", "scale=72:-2", "-f", "image2", "-c:v", "mjpeg", "-").Output()
	return thumb, w, h, uint32(secs)
}

func sendFile(jid, path, caption, tmp, quote string) {
	fail := func(why string) {
		emit(map[string]any{"t": "done", "op": "send", "ok": false, "jid": jid, "tmp": tmp, "msg": why})
	}
	j, err := types.ParseJID(jid)
	if err != nil {
		return
	}
	data, err := os.ReadFile(path)
	if err != nil {
		fail("Can't read that file")
		return
	}
	if len(data) > 100<<20 {
		fail("Too big for WhatsApp (100 MB)")
		return
	}
	if !cli.IsConnected() {
		fail("Not connected")
		return
	}
	caption = strings.TrimSpace(caption)
	kind, mt := kindOf(path, data)
	var thumbJPEG []byte
	var w, h int
	var secs uint32
	if kind == "image" {
		if jp, small, iw, ih, err := asJPEG(data); err == nil {
			data, thumbJPEG, w, h, mt = jp, small, iw, ih, "image/jpeg"
		} else {
			kind = "doc"
		}
	} else if kind == "video" {
		thumbJPEG, w, h, secs = videoThumb(path)
	}
	media := map[string]whatsmeow.MediaType{"image": whatsmeow.MediaImage, "video": whatsmeow.MediaVideo, "audio": whatsmeow.MediaAudio, "doc": whatsmeow.MediaDocument}[kind]
	uctx, cancel := context.WithTimeout(ctx, 5*time.Minute)
	defer cancel()
	up, err := cli.Upload(uctx, data, media)
	if err != nil {
		fmt.Fprintf(os.Stderr, "lumen-wa upload: %v\n", err)
		fail("Couldn't upload it")
		return
	}
	ci, qfrom, qtext := quoting(jid, quote)
	name := filepath.Base(path)
	msg := &waE2E.Message{}
	switch kind {
	case "image":
		msg.ImageMessage = &waE2E.ImageMessage{
			Caption: proto.String(caption), Mimetype: proto.String(mt), JPEGThumbnail: thumbJPEG,
			Width: proto.Uint32(uint32(w)), Height: proto.Uint32(uint32(h)),
			URL: proto.String(up.URL), DirectPath: proto.String(up.DirectPath), MediaKey: up.MediaKey,
			FileEncSHA256: up.FileEncSHA256, FileSHA256: up.FileSHA256, FileLength: proto.Uint64(up.FileLength), ContextInfo: ci,
		}
	case "video":
		msg.VideoMessage = &waE2E.VideoMessage{
			Caption: proto.String(caption), Mimetype: proto.String(mt), JPEGThumbnail: thumbJPEG,
			Width: proto.Uint32(uint32(w)), Height: proto.Uint32(uint32(h)), Seconds: proto.Uint32(secs),
			URL: proto.String(up.URL), DirectPath: proto.String(up.DirectPath), MediaKey: up.MediaKey,
			FileEncSHA256: up.FileEncSHA256, FileSHA256: up.FileSHA256, FileLength: proto.Uint64(up.FileLength), ContextInfo: ci,
		}
	case "audio":
		msg.AudioMessage = &waE2E.AudioMessage{
			Mimetype: proto.String(mt),
			URL:      proto.String(up.URL), DirectPath: proto.String(up.DirectPath), MediaKey: up.MediaKey,
			FileEncSHA256: up.FileEncSHA256, FileSHA256: up.FileSHA256, FileLength: proto.Uint64(up.FileLength), ContextInfo: ci,
		}
	default:
		msg.DocumentMessage = &waE2E.DocumentMessage{
			FileName: proto.String(name), Title: proto.String(name), Caption: proto.String(caption), Mimetype: proto.String(mt),
			URL: proto.String(up.URL), DirectPath: proto.String(up.DirectPath), MediaKey: up.MediaKey,
			FileEncSHA256: up.FileEncSHA256, FileSHA256: up.FileSHA256, FileLength: proto.Uint64(up.FileLength), ContextInfo: ci,
		}
	}
	sctx, cancel2 := context.WithTimeout(ctx, 30*time.Second)
	defer cancel2()
	resp, err := cli.SendMessage(sctx, j, msg)
	if err != nil {
		fmt.Fprintf(os.Stderr, "lumen-wa send file to %s: %v\n", j.Server, err)
		fail("Couldn't send")
		return
	}
	// Kept as one that came in would be: what it says, and the file itself (no download needed to open it).
	text, _ := describe(msg)
	ext := map[string]string{"image": ".jpg", "video": ".mp4"}[kind]
	if ext == "" {
		ext = filepath.Ext(name)
	}
	local := filepath.Join(cacheDir, "media", safe(resp.ID)+ext)
	if os.WriteFile(local, data, 0o600) != nil {
		local = ""
	}
	raw, _ := proto.Marshal(msg)
	m := row{Chat: jid, ID: resp.ID, Me: true, Text: text, TS: resp.Timestamp.Unix(), Kind: kind, Media: local, W: w, H: h, St: 1, QFrom: qfrom, QText: qtext}
	m.save(raw)
	db.Exec(`INSERT INTO chats (jid, ts) VALUES (?, ?) ON CONFLICT (jid) DO UPDATE SET ts = MAX(ts, excluded.ts), unread = 0`, jid, m.TS)
	emit(map[string]any{"t": "msg", "jid": jid, "live": false, "tmp": tmp, "msg": m.json()})
	emit(map[string]any{"t": "done", "op": "send", "ok": true, "jid": jid, "tmp": tmp})
	touch()
}
