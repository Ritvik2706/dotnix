package main

// Catching up on demand, and after the laptop wakes.
//
// A connection can die without a word: after a suspend the socket is gone
// but no Disconnected event comes, so whatsmeow's auto-reconnect never
// starts and the chats stop moving (seen 2026-11-16: no socket at all, the
// newest message hours old). `resync` drops whatever is left of the
// connection, connects again (WhatsApp then hands over what was missed, as
// an offline sync), fetches the app state again (names, mutes, pins,
// archived) and sends the chats. The island shows it as its usual
// "Updating… → Up to date" and reloads the open chat.
//
// Asked for by the island ({"op": "sync"}: R or :sync in the view) and done
// by itself when logind says the machine woke up (PrepareForSleep false),
// watched with `gdbus monitor`: an event, no polling.

import (
	"bufio"
	"fmt"
	"os"
	"os/exec"
	"strings"
	"sync"
	"syscall"
	"time"

	"go.mau.fi/whatsmeow/appstate"
)

var resyncMu sync.Mutex

func resync(why string) {
	if !resyncMu.TryLock() {
		return // one at a time; a second ask while it runs is the same ask
	}
	defer resyncMu.Unlock()
	if cli == nil || cli.Store.ID == nil {
		return // not linked: nothing to catch up on
	}
	fmt.Fprintln(os.Stderr, "lumen-wa resync:", why)
	emit(map[string]any{"t": "sync", "on": true, "done": 0, "total": 10})

	cli.Disconnect()
	connect() // keeps trying until it is back
	for i := 0; i < 150 && !cli.IsLoggedIn(); i++ {
		time.Sleep(100 * time.Millisecond)
	}
	if !cli.IsLoggedIn() {
		emit(map[string]any{"t": "sync", "on": false, "done": 0, "total": 10})
		state("offline", "Can't reach WhatsApp, trying again…")
		return
	}
	emit(map[string]any{"t": "sync", "on": true, "done": 4, "total": 10})

	for i, name := range appstate.AllPatchNames {
		if err := cli.FetchAppState(ctx, name, false, false); err != nil {
			fmt.Fprintln(os.Stderr, "lumen-wa appstate:", name, err)
		}
		emit(map[string]any{"t": "sync", "on": true, "done": 5 + i, "total": 10})
	}
	lastChats = ""
	sendChats()
	// An offline sync WhatsApp started on reconnecting ends itself (endSync);
	// otherwise this is the end.
	if !syncing.Load() {
		emit(map[string]any{"t": "sync", "on": false, "done": 10, "total": 10})
	}
}

// watchResume runs `gdbus monitor` on logind and resyncs after every wake.
// gdbus dies with us (Pdeathsig); if it exits on its own it is started again.
func watchResume() {
	for {
		cmd := exec.Command("gdbus", "monitor", "--system",
			"--dest", "org.freedesktop.login1", "--object-path", "/org/freedesktop/login1")
		cmd.SysProcAttr = &syscall.SysProcAttr{Pdeathsig: syscall.SIGTERM}
		out, err := cmd.StdoutPipe()
		if err != nil || cmd.Start() != nil {
			return // no gdbus: R / :sync still work
		}
		sc := bufio.NewScanner(out)
		for sc.Scan() {
			if strings.Contains(sc.Text(), "PrepareForSleep (false") {
				// give the network a moment to come back; connect() retries anyway
				go func() {
					time.Sleep(3 * time.Second)
					resync("woke up")
				}()
			}
		}
		cmd.Wait()
		time.Sleep(30 * time.Second)
	}
}
