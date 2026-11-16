package main

// Voice notes, as iMessage shows them: a play button, the note's own waveform and its length. WhatsApp
// sends the waveform with every voice note (AudioMessage.Waveform: 64 levels, 0–100); it is drawn here
// once into a small white picture (media/<id>-w.png), which the island tints to the bubble's ink. A
// note without one (an old client, a forwarded file) gets a soft pattern of its own, from its id, so
// it still reads as a voice note and not as a file. A longer note has more bars (barsFor), so its
// bubble is as long as it is; the bars sit centred in a picture of one size for all (the island's
// canvas), and the island draws it with the bubble as wide as they are.

import (
	"hash/fnv"
	"image"
	"image/color"
	"image/png"
	"math"
	"os"
	"path/filepath"

	"go.mau.fi/whatsmeow/proto/waE2E"
	"google.golang.org/protobuf/proto"
)

const (
	waveMost = 64 // bars across, at most
	waveW    = waveMost * 6
	waveH    = 48 // drawn at half that: crisp at 2×
)

// How many bars a note of this length gets: a few seconds 20, a minute or more 64 (34 when the
// length is not known). The island lays the bubble out from this number.
func barsFor(secs int) int {
	if secs <= 0 {
		return 34
	}
	return max(20, min(waveMost, int(math.Round(8*math.Sqrt(float64(secs))+6))))
}

// A voice note's length (seconds), its bars and its waveform's picture, from the message as it came.
func voiceOf(r row) (int, int, string) {
	var raw []byte
	db.QueryRow(`SELECT raw FROM msgs WHERE chat = ? AND id = ?`, r.Chat, r.ID).Scan(&raw)
	msg := &waE2E.Message{}
	var a *waE2E.AudioMessage
	if len(raw) > 0 && proto.Unmarshal(raw, msg) == nil {
		a = msg.GetAudioMessage()
	}
	secs := int(a.GetSeconds())
	bars := barsFor(secs)
	path := filepath.Join(cacheDir, "media", safe(r.ID)+"-v.png")
	if exists(path) {
		return secs, bars, path
	}
	levels := make([]float64, bars)
	if wf := a.GetWaveform(); len(wf) > 0 {
		// The 64 levels into the bars, each the loudest of its share (or, with more bars than
		// levels, one level over two bars).
		for i := range levels {
			lo, hi := i*len(wf)/bars, (i+1)*len(wf)/bars
			if hi <= lo {
				hi = lo + 1
			}
			for _, v := range wf[lo:min(hi, len(wf))] {
				levels[i] = math.Max(levels[i], float64(v)/100)
			}
		}
	} else {
		h := fnv.New32a()
		h.Write([]byte(r.ID))
		seed := float64(h.Sum32()%1000) / 100
		for i := range levels {
			x := float64(i)
			levels[i] = 0.35 + 0.3*math.Sin(x*0.7+seed) + 0.2*math.Sin(x*1.9+seed*2)
		}
	}
	img := image.NewNRGBA(image.Rect(0, 0, waveW, waveH))
	left := (waveMost - bars) * 3 // centred
	for i, l := range levels {
		l = math.Max(0.12, math.Min(1, l))
		bh := int(math.Round(l * waveH))
		x0, y0 := left+i*6+1, (waveH-bh)/2
		for y := y0; y < y0+bh; y++ {
			for x := x0; x < x0+4; x++ {
				// The bar's ends rounded: the corner pixels fade.
				a := uint8(255)
				if (y == y0 || y == y0+bh-1) && (x == x0 || x == x0+3) {
					a = 90
				}
				img.SetNRGBA(x, y, color.NRGBA{255, 255, 255, a})
			}
		}
	}
	f, err := os.Create(path)
	if err != nil {
		return secs, bars, ""
	}
	defer f.Close()
	if png.Encode(f, img) != nil {
		return secs, bars, ""
	}
	return secs, bars, path
}
