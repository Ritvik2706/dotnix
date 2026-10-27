#!/usr/bin/env python3
# The island's Gmail: one process that stays up, spawned by island.luau.
#
# It keeps two IMAP connections to imap.gmail.com: one IDLEs on the inbox and
# only says "something changed", the other does what the island asks. The
# island writes one JSON object per line on stdin and gets one per line back:
#
#   in   {"op": "refresh"}  {"op": "body", "uid": 12}  {"op": "seen", "uid": 12, "v": true}
#        {"op": "archive", "uid": 12}  {"op": "trash", "uid": 12}
#        {"op": "reply", "uid": 12, "text": "…"}
#   out  {"t": "state", "state": "ok" | "nocreds" | "auth" | "offline", "msg": "…", "account": "…"}
#        {"t": "list", "unread": 3, "msgs": [{uid, from, addr, subject, date, unread, url}, …]}  newest first
#        {"t": "body", "uid": 12, "text": "…", "to": "…"}
#        {"t": "done", "op": "reply", "uid": 12, "ok": true, "msg": "…"}
#
# Credentials: ~/.local/share/lumen/gmail.conf (outside the dotfiles), mode 600:
#   address = you@gmail.com
#   password = the 16-letter app password
# or, if a Secret Service is running, `secret-tool store --label="lumen gmail"
# service lumen-gmail user you@gmail.com`.

import base64
import concurrent.futures
import email
import email.header
import email.policy
import email.utils
import hashlib
import html.parser
import imaplib
import json
import os
import queue
import re
import shutil
import signal
import smtplib
import subprocess
import sys
import threading
import time
import urllib.request
from email.message import EmailMessage

HOST = "imap.gmail.com"
LIST_N = 40
CONF = os.path.expanduser("~/.local/share/lumen/gmail.conf")

out_lock = threading.Lock()


def say(obj):
    with out_lock:
        sys.stdout.write(json.dumps(obj, ensure_ascii=False) + "\n")
        sys.stdout.flush()


def credentials():
    if os.path.exists(CONF):
        conf = {}
        with open(CONF) as f:
            for line in f:
                if "=" in line and not line.lstrip().startswith("#"):
                    k, v = line.split("=", 1)
                    conf[k.strip().lower()] = v.strip()
        if conf.get("address") and conf.get("password"):
            return conf["address"], conf["password"].replace(" ", "")
    try:
        found = subprocess.run(["secret-tool", "search", "service", "lumen-gmail"], capture_output=True, text=True, timeout=5).stdout
        user = re.search(r"^attribute\.user = (.+)$", found, re.M)
        if user:
            pw = subprocess.run(["secret-tool", "lookup", "service", "lumen-gmail", "user", user.group(1)], capture_output=True, text=True, timeout=5).stdout
            if pw.strip():
                return user.group(1).strip(), pw.strip().replace(" ", "")
    except (OSError, subprocess.TimeoutExpired):
        pass
    return None, None


ADDR, PW = credentials()


def connect():
    conn = imaplib.IMAP4_SSL(HOST, timeout=30)
    conn.login(ADDR, PW)
    conn.select("INBOX")
    return conn


# ── reading what IMAP hands back ────────────────────────────────


def header_text(raw):
    try:
        return str(email.header.make_header(email.header.decode_header(raw or ""))).strip()
    except Exception:
        return (raw or "").strip()


def sender(raw):
    name, addr = email.utils.parseaddr(header_text(raw))
    return (name or addr.split("@")[0] or "Unknown").strip('"'), addr


def web_url(thrid):
    return f"https://mail.google.com/mail/u/{ADDR}/#all/{int(thrid):x}" if thrid else f"https://mail.google.com/mail/u/{ADDR}/#inbox"


def fetch_list(conn):
    typ, data = conn.uid("SEARCH", None, "ALL")
    uids = (data[0] or b"").split()[-LIST_N:]
    msgs = []
    if uids:
        typ, data = conn.uid("FETCH", b",".join(uids), "(UID FLAGS X-GM-THRID INTERNALDATE BODY.PEEK[HEADER.FIELDS (FROM SUBJECT)])")
        for part in data:
            if not isinstance(part, tuple):
                continue
            meta = part[0].decode(errors="replace")
            uid = re.search(r"UID (\d+)", meta)
            if not uid:
                continue
            flags = re.search(r"FLAGS \(([^)]*)\)", meta)
            thrid = re.search(r"X-GM-THRID (\d+)", meta)
            when = re.search(r'INTERNALDATE "([^"]+)"', meta)
            head = email.message_from_bytes(part[1])
            name, addr = sender(head.get("From"))
            stamp = 0
            if when:
                try:
                    stamp = int(time.mktime(imaplib.Internaldate2tuple(f'INTERNALDATE "{when.group(1)}"'.encode())))
                except Exception:
                    stamp = 0
            msgs.append({
                "uid": int(uid.group(1)), "from": name, "addr": addr,
                "subject": re.sub(r"\s+", " ", header_text(head.get("Subject"))) or "(no subject)",
                "date": stamp, "unread": "\\Seen" not in (flags.group(1) if flags else ""),
                "url": web_url(thrid.group(1) if thrid else None),
            })
    msgs.sort(key=lambda m: m["uid"], reverse=True)
    typ, data = conn.status("INBOX", "(UNSEEN)")
    unread = re.search(rb"UNSEEN (\d+)", data[0] or b"")
    say({"t": "list", "unread": int(unread.group(1)) if unread else 0, "msgs": msgs})


# ── a mail as the island shows it: blocks of text (markdown: its links are
# links) and its pictures, fetched to a cache, each with its size ──────────

CACHE = os.path.expanduser("~/.cache/lumen/mail")
MD_SPECIAL = re.compile(r"([\\`*_\[\]])")
URL = re.compile(r"(?<![\w(\[])((?:https?://|www\.)[^\s<>()\[\]]+[^\s<>()\[\].,;:!?'\"])")


def md_escape(s):
    return MD_SPECIAL.sub(r"\\\1", s)


def md_link(words, href):
    href = href.strip().replace(" ", "%20").replace("(", "%28").replace(")", "%29")
    words = re.sub(r"\s+", " ", words).strip()
    return f"[{words}]({href})" if words and href else words


def linkify(plain):
    """A text mail: escaped, with its bare addresses made links."""
    out, last = [], 0
    for m in URL.finditer(plain):
        out.append(md_escape(plain[last:m.start()]))
        url = m.group(1)
        out.append(md_link(md_escape(url), url if url.startswith("http") else "https://" + url))
        last = m.end()
    out.append(md_escape(plain[last:]))
    return "".join(out)


class Blocks(html.parser.HTMLParser):
    """An HTML mail as blocks: runs of markdown text, and the pictures between them."""

    BREAK = {"br", "p", "div", "tr", "li", "table", "blockquote", "hr", "h1", "h2", "h3", "h4", "h5", "h6"}

    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.blocks, self.text, self.skip = [], [], 0
        self.href, self.link_words = None, None

    def flush(self):
        t = tidy("".join(self.text))
        if t:
            self.blocks.append({"md": t})
        self.text = []

    def put(self, s):
        if self.link_words is not None:
            self.link_words.append(s)
        else:
            self.text.append(s)

    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        if tag in ("style", "script", "head", "title"):
            self.skip += 1
        elif self.skip:
            return
        elif tag == "a" and (a.get("href") or "").startswith(("http", "mailto:")):
            self.href, self.link_words = a["href"], []
        elif tag == "img":
            self.image(a)
        elif tag in self.BREAK:
            self.put("\n")
            if tag in ("h1", "h2", "h3"):
                self.put("## ")
            elif tag == "li":
                self.put("• ")

    def handle_startendtag(self, tag, attrs):
        self.handle_starttag(tag, attrs)

    def handle_endtag(self, tag):
        if tag in ("style", "script", "head", "title"):
            self.skip = max(0, self.skip - 1)
        elif self.skip:
            return
        elif tag == "a" and self.link_words is not None:
            words, href = "".join(self.link_words), self.href
            self.href, self.link_words = None, None
            self.put(md_link(words, href))
        elif tag in ("p", "div", "tr", "table", "h1", "h2", "h3", "blockquote"):
            self.put("\n")

    def handle_data(self, data):
        if not self.skip:
            self.put(md_escape(re.sub(r"[ \t\r\n ]+", " ", data)))

    def image(self, a):
        src = (a.get("src") or "").strip()
        # A tracking pixel or a spacer says so in its size.
        try:
            if min(int(re.sub(r"\D", "", a.get("width", "99") or "99") or 99), int(re.sub(r"\D", "", a.get("height", "99") or "99") or 99)) < 16:
                return
        except ValueError:
            pass
        if not src:
            return
        # A picture inside a link: the text so far is closed off, the link stays open for after it.
        if self.link_words is not None:
            words = "".join(self.link_words)
            if words.strip():
                self.text.append(md_link(words, self.href))
            self.link_words = []
        self.flush()
        self.blocks.append({"src": src, "href": self.href or "", "alt": a.get("alt", "")})


def tidy(s):
    s = s.replace("\r", "")
    s = re.sub(r"[ \t ‌​͏]+\n", "\n", s)
    s = re.sub(r"\n[ \t]+", "\n", s)
    s = re.sub(r"\n{3,}", "\n\n", s)
    s = re.sub(r"[‌​͏­ ]", "", s)
    s = re.sub(r"(?m)^## *$", "", s)
    return s.strip()


def picture_size(data):
    """Width and height from the first bytes of a PNG, GIF, JPEG or WebP."""
    if data[:8] == b"\x89PNG\r\n\x1a\n":
        return int.from_bytes(data[16:20], "big"), int.from_bytes(data[20:24], "big")
    if data[:6] in (b"GIF87a", b"GIF89a"):
        return int.from_bytes(data[6:8], "little"), int.from_bytes(data[8:10], "little")
    if data[:4] == b"RIFF" and data[8:12] == b"WEBP":
        kind = data[12:16]
        if kind == b"VP8 ":
            return int.from_bytes(data[26:28], "little") & 0x3FFF, int.from_bytes(data[28:30], "little") & 0x3FFF
        if kind == b"VP8L":
            b = int.from_bytes(data[21:25], "little")
            return (b & 0x3FFF) + 1, ((b >> 14) & 0x3FFF) + 1
        if kind == b"VP8X":
            return int.from_bytes(data[24:27], "little") + 1, int.from_bytes(data[27:30], "little") + 1
    if data[:2] == b"\xff\xd8":
        i = 2
        while i + 9 < len(data):
            if data[i] != 0xFF:
                i += 1
                continue
            marker = data[i + 1]
            if marker in (0xC0, 0xC1, 0xC2, 0xC3, 0xC5, 0xC6, 0xC7, 0xC9, 0xCA, 0xCB, 0xCD, 0xCE, 0xCF):
                return int.from_bytes(data[i + 7:i + 9], "big"), int.from_bytes(data[i + 5:i + 7], "big")
            i += 2 + int.from_bytes(data[i + 2:i + 4], "big")
    return None


def keep_picture(data):
    """In the cache, by what it is; its path and size, or None if it is no picture lumen shows (or a speck)."""
    size = picture_size(data)
    if not size or min(size) < 16:
        return None
    ext = {b"\x89P": "png", b"GI": "gif", b"RI": "webp", b"\xff\xd8": "jpg"}.get(data[:2], "img")
    os.makedirs(CACHE, exist_ok=True)
    path = os.path.join(CACHE, hashlib.sha1(data).hexdigest()[:20] + "." + ext)
    if not os.path.exists(path):
        with open(path + ".part", "wb") as f:
            f.write(data)
        os.replace(path + ".part", path)
    return path, size


fetched = {}     # address → (path, size): a mail opened again does not fetch its pictures again


def fetch_picture(src, inline, remote=True):
    if src in fetched:
        return fetched[src]
    try:
        if src.startswith("cid:"):
            data = inline.get(src[4:].strip("<>"))
        elif src.startswith("data:image/") and ";base64," in src:
            data = base64.b64decode(src.split(",", 1)[1])
        elif src.startswith(("http://", "https://")) and remote:
            req = urllib.request.Request(src, headers={"User-Agent": "Mozilla/5.0 (X11; Linux x86_64)"})
            with urllib.request.urlopen(req, timeout=8) as r:
                data = r.read(8_000_000)
            fetched[src] = keep_picture(data) if data else None
            return fetched[src]
        else:
            return None
        return keep_picture(data) if data else None
    except Exception:
        return None


def blocks_of(msg, remote=True):
    """Its blocks, and whether pictures on the web were left out (`remote` false: the words come first)."""
    html_part = msg.get_body(preferencelist=("html",))
    blocks = []
    if html_part is not None:
        try:
            content = html_part.get_content()
        except Exception:
            content = (html_part.get_payload(decode=True) or b"").decode("utf-8", "replace")
        p = Blocks()
        p.feed(content)
        p.flush()
        blocks = p.blocks
    else:
        blocks = [{"md": linkify(plain_text(msg))}]
    # What the pictures are: the ones inside the mail by their Content-ID, the rest fetched (a few at a time).
    inline = {}
    for part in msg.walk():
        cid = (part.get("Content-ID") or "").strip("<> ")
        if cid and part.get_content_maintype() == "image":
            inline[cid] = part.get_payload(decode=True)
    pics = [b for b in blocks if "src" in b][:24]
    left = any(b["src"].startswith("http") and b["src"] not in fetched for b in pics) and not remote
    with concurrent.futures.ThreadPoolExecutor(6) as pool:
        got = list(pool.map(lambda b: fetch_picture(b["src"], inline, remote), pics))
    for b, g in zip(pics, got):
        if g:
            b["img"], (b["w"], b["h"]) = g[0], g[1]
    out = []
    for b in blocks:
        if "md" in b:
            if out and "md" in out[-1]:
                out[-1]["md"] += "\n\n" + b["md"]
            else:
                out.append({"md": b["md"]})
        elif "img" in b:
            out.append({"img": b["img"], "w": b["w"], "h": b["h"], "href": b["href"]})
    # Pictures attached, not placed in the text: at the end, and the other files named.
    placed = {b["img"] for b in out if "img" in b}
    files = []
    for a in msg.iter_attachments():
        if a.get_content_maintype() == "image" and len(out) < 40:
            g = keep_picture(a.get_payload(decode=True) or b"")
            if g and g[0] not in placed:
                out.append({"img": g[0], "w": g[1][0], "h": g[1][1], "href": ""})
                continue
        if a.get_filename():
            files.append("📎 " + md_escape(header_text(a.get_filename())))
    if files:
        out.append({"md": "\n".join(files)})
    if not out:
        out = [{"md": "(This message has no text.)"}]
    return out[:48], left


def plain_text(msg):
    """The words alone (a reply quotes them)."""
    part = msg.get_body(preferencelist=("plain", "html"))
    if part is None:
        return ""
    try:
        content = part.get_content()
    except Exception:
        content = (part.get_payload(decode=True) or b"").decode("utf-8", "replace")
    if part.get_content_type() == "text/html":
        p = Blocks()
        p.feed(content)
        p.flush()
        content = "\n\n".join(re.sub(r"\[([^\]]*)\]\([^)]*\)", r"\1", b["md"]).replace("\\", "") for b in p.blocks if "md" in b)
    return tidy(content)[:16000]


def fetch_message(conn, uid):
    typ, data = conn.uid("FETCH", str(uid), "(RFC822.SIZE)")
    size = re.search(rb"RFC822\.SIZE (\d+)", data[0] or b"") if data and data[0] else None
    # A big attachment is not read whole: the text comes first, the rest is cut.
    what = "BODY.PEEK[]<0.1500000>" if size and int(size.group(1)) > 2_000_000 else "BODY.PEEK[]"
    typ, data = conn.uid("FETCH", str(uid), f"({what})")
    raw = next((p[1] for p in data if isinstance(p, tuple)), None)
    if raw is None:
        raise RuntimeError("That message is gone")
    return email.message_from_bytes(raw, policy=email.policy.default)


def message_id(conn, uid):
    """Its Message-ID: what finds it again once it has left the inbox (its uid does not follow it)."""
    typ, data = conn.uid("FETCH", str(uid), "(BODY.PEEK[HEADER.FIELDS (MESSAGE-ID)])")
    raw = next((p[1] for p in data if isinstance(p, tuple)), b"")
    return (email.message_from_bytes(raw).get("Message-ID") or "").strip()


def special_box(conn, flag, fallback):
    typ, data = conn.list()
    for line in data or []:
        line = line.decode(errors="replace")
        if flag in line:
            return line.rsplit(' "/" ', 1)[-1]
    return fallback


def restore(conn, mid, was):
    """Undo: the mail found by its Message-ID back in the inbox, from the Bin or from All Mail."""
    box = special_box(conn, "\\Trash", '"[Gmail]/Trash"') if was == "trash" else special_box(conn, "\\All", '"[Gmail]/All Mail"')
    try:
        conn.select(box)
        typ, data = conn.uid("SEARCH", None, "HEADER", "Message-ID", mid)
        found = (data[0] or b"").split()
        if not found:
            raise RuntimeError("It was not found to put back")
        if was == "trash":
            conn.uid("MOVE", found[-1].decode(), "INBOX")
        else:
            conn.uid("STORE", found[-1].decode(), "+X-GM-LABELS", "(\\Inbox)")
    finally:
        conn.select("INBOX")


def trash_box(conn):
    typ, data = conn.list()
    for line in data or []:
        line = line.decode(errors="replace")
        if "\\Trash" in line:
            return line.rsplit(" ", 1)[-1] if not line.endswith('"') else '"' + line.rsplit(' "', 1)[-1]
    return '"[Gmail]/Trash"'


def reply(conn, uid, text):
    orig = fetch_message(conn, uid)
    to = orig.get("Reply-To") or orig.get("From")
    subject = str(orig.get("Subject") or "")
    if not re.match(r"(?i)^re:", subject):
        subject = "Re: " + subject
    mid = orig.get("Message-ID")
    m = EmailMessage()
    m["From"] = ADDR
    m["To"] = to
    m["Subject"] = subject
    if mid:
        m["In-Reply-To"] = mid
        m["References"] = ((orig.get("References") or "") + " " + mid).strip()
    quoted = "\n".join("> " + l for l in plain_text(orig).splitlines())
    m.set_content(f"{text}\n\nOn {orig.get('Date')}, {orig.get('From')} wrote:\n{quoted}\n")
    with smtplib.SMTP_SSL("smtp.gmail.com", 465, timeout=30) as s:
        s.login(ADDR, PW)
        s.send_message(m)
    conn.uid("STORE", str(uid), "+FLAGS", "(\\Answered)")
    return header_text(str(to))


# ── a mail as Gmail shows it: rendered by a headless Firefox ───────────
# For the large view. Firefox is driven over WebDriver BiDi (a WebSocket):
# the mail's HTML, its own scripts shut out by a Content-Security-Policy, is
# laid out at the reader's width, photographed in tiles of TILE px (the
# island's atlas takes pictures of a moderate size) and its links measured, so
# the island can lay a zone over each. It starts with the first mail and
# leaves after a few idle minutes.

RENDER_W = 620          # the reader's width, in CSS px
TILE = 600              # a tile's height
MOST = 4800             # no longer than this: the rest is Gmail's
MOST_ZOOMED = 2400      # drawn larger (the focused view), only this much: its tiles weigh more
DPR = 1.6               # the screen's scale: tiles as sharp as the island draws them


class WebSocket:
    """Just enough of RFC 6455 for one local connection: text frames, fragmented or not."""

    def __init__(self, url):
        import socket
        host, port, path = re.match(r"ws://([^:/]+):(\d+)(/.*)?", url).groups()
        self.sock = socket.create_connection((host, int(port)), timeout=30)
        key = base64.b64encode(os.urandom(16)).decode()
        self.sock.sendall((f"GET {path or '/'} HTTP/1.1\r\nHost: {host}:{port}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                           f"Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n").encode())
        head = b""
        while b"\r\n\r\n" not in head:
            chunk = self.sock.recv(1)
            if not chunk:
                raise OSError("Firefox closed the connection")
            head += chunk
        if b" 101 " not in head.split(b"\r\n", 1)[0]:
            raise OSError("Firefox refused the WebSocket: " + head.split(b"\r\n", 1)[0].decode(errors="replace"))

    def exact(self, n):
        buf = bytearray()
        while len(buf) < n:
            chunk = self.sock.recv(min(n - len(buf), 1 << 20))
            if not chunk:
                raise OSError("Firefox closed the connection")
            buf += chunk
        return bytes(buf)

    def send(self, text):
        data = text.encode()
        head = bytearray([0x81])
        n = len(data)
        if n < 126:
            head.append(0x80 | n)
        elif n < 65536:
            head += bytes([0x80 | 126]) + n.to_bytes(2, "big")
        else:
            head += bytes([0x80 | 127]) + n.to_bytes(8, "big")
        mask = os.urandom(4)
        head += mask
        self.sock.sendall(bytes(head) + bytes(b ^ mask[i % 4] for i, b in enumerate(data)))

    def recv(self):
        parts = []
        while True:
            b0, b1 = self.exact(2)
            n = b1 & 0x7F
            if n == 126:
                n = int.from_bytes(self.exact(2), "big")
            elif n == 127:
                n = int.from_bytes(self.exact(8), "big")
            payload = self.exact(n)
            op = b0 & 0x0F
            if op == 0x8:
                raise OSError("Firefox closed the connection")
            if op in (0x9, 0xA):
                continue
            parts.append(payload)
            if b0 & 0x80:
                return b"".join(parts).decode()

    def close(self):
        try:
            self.sock.close()
        except OSError:
            pass


def die_with_us():
    """Run in the child before Firefox starts: the kernel kills it the moment this script goes,
    however it goes (SIGKILL included). Without it every reload of the island left one behind."""
    import ctypes
    ctypes.CDLL(None, use_errno=True).prctl(1, signal.SIGKILL)   # PR_SET_PDEATHSIG
    if os.getppid() == 1:                                          # we were already gone
        os._exit(1)


def sweep_profiles():
    """Profiles left in /tmp by a Firefox that no longer runs."""
    import glob
    import tempfile
    live = set()
    for cmd in glob.glob("/proc/[0-9]*/cmdline"):
        try:
            with open(cmd, "rb") as f:
                live.update(a.decode(errors="replace") for a in f.read().split(b"\0"))
        except OSError:
            pass
    for prof in glob.glob(os.path.join(tempfile.gettempdir(), "lumen-mail-*")):
        if prof not in live:
            shutil.rmtree(prof, ignore_errors=True)


class Firefox:
    def __init__(self):
        self.proc, self.ws, self.ctx, self.next_id, self.used, self.prof = None, None, None, 0, 0, None

    def start(self):
        import tempfile
        prof = self.prof = tempfile.mkdtemp(prefix="lumen-mail-")
        with open(os.path.join(prof, "user.js"), "w") as f:
            for k, v in {"browser.shell.checkDefaultBrowser": "false", "datareporting.policy.dataSubmissionEnabled": "false",
                         "toolkit.telemetry.enabled": "false", "app.update.auto": "false", "browser.startup.page": "0",
                         "ui.systemUsesDarkTheme": "0", "layout.css.prefers-color-scheme.content-override": "1",
                         "network.cookie.cookieBehavior": "2", "browser.cache.disk.enable": "false"}.items():
                f.write(f'user_pref("{k}", {v});\n')
        self.proc = subprocess.Popen(["firefox", "--headless", "--no-remote", "-profile", prof, "--remote-debugging-port", "0", "about:blank"],
                                     stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True, preexec_fn=die_with_us)
        url = None
        deadline = time.time() + 20
        while time.time() < deadline:
            line = self.proc.stderr.readline()
            if not line:
                break
            m = re.search(r"WebDriver BiDi listening on (ws://\S+)", line)
            if m:
                url = m.group(1)
                break
        if not url:
            self.stop()
            raise OSError("Firefox did not start")
        threading.Thread(target=lambda: [None for _ in self.proc.stderr], daemon=True).start()
        self.ws = WebSocket(url.rstrip("/") + "/session")
        self.call("session.new", {"capabilities": {}})
        self.ctx = self.call("browsingContext.getTree", {})["contexts"][0]["context"]

    def stop(self):
        if self.ws:
            try:
                self.ws.close()
            except Exception:
                pass
        if self.proc:
            self.proc.kill()
            try:
                self.proc.wait(5)
            except Exception:
                pass
        if self.prof:
            shutil.rmtree(self.prof, ignore_errors=True)
        self.proc, self.ws, self.ctx, self.prof = None, None, None, None

    def call(self, method, params):
        self.next_id += 1
        me = self.next_id
        self.ws.send(json.dumps({"id": me, "method": method, "params": params}))
        while True:
            msg = json.loads(self.ws.recv())
            if msg.get("id") == me:
                if msg.get("type") == "error":
                    raise RuntimeError(f"{method}: {msg.get('error')} {msg.get('message', '')[:160]}")
                return msg.get("result", {})

    def render(self, page, stem, scale=1.0):
        """The page (a file) laid out and photographed: its tiles, its height, its links.
        `scale`: drawn that much larger (the focused view), the same layout photographed finer."""
        most = MOST if scale <= 1.0 else MOST_ZOOMED
        if self.proc is None or self.proc.poll() is not None:
            self.stop()
            self.start()
        self.used = time.time()
        c = self.ctx
        self.call("browsingContext.setViewport", {"context": c, "viewport": {"width": RENDER_W, "height": TILE}, "devicePixelRatio": DPR * scale})
        self.call("browsingContext.navigate", {"context": c, "url": "file://" + page, "wait": "interactive"})
        # Its pictures, as many as come within three seconds: a slow server does not hold the mail up.
        self.call("script.evaluate", {"expression": """new Promise(done => {
            const left = [...document.images].filter(i => !i.complete);
            let n = left.length; if (!n) return done(true);
            left.forEach(i => { const one = () => { if (--n <= 0) done(true); }; i.addEventListener('load', one); i.addEventListener('error', one); });
            setTimeout(() => done(false), 3000);
        })""", "target": {"context": c}, "awaitPromise": True, "resultOwnership": "none"})
        # A mail wider than the reader is shrunk to it, as Gmail does; then how tall it is, and where its links are.
        measure = """(() => {
            const d = document.documentElement, b = document.body;
            const wide = Math.max(d.scrollWidth, b ? b.scrollWidth : 0);
            if (wide > %d) { d.style.zoom = (%d / wide).toString(); }
            // (This Firefox reports boxes already zoomed: no scaling them again.)
            const h = Math.min(%d, Math.ceil(Math.max(d.getBoundingClientRect().height, 1)));
            const k = parseFloat(d.style.zoom) || 1;
            const links = [];
            for (const a of document.querySelectorAll('a[href]')) {
                const href = a.href;
                if (!/^(https?:|mailto:)/.test(href)) continue;
                for (const r of a.getClientRects()) {
                    if (r.width < 2 || r.height < 2) continue;
                    const y = r.top + window.scrollY;
                    if (y > h) continue;
                    links.push({x: r.left, y: y, w: r.width, h: r.height, href: href});
                    if (links.length >= 150) break;
                }
            }
            // Its pictures (big enough to matter): the helper keeps the ones that move, to play them over the photograph.
            const imgs = [];
            [...document.images].forEach((im, i) => {
                const r = im.getBoundingClientRect(), y = r.top + window.scrollY;
                if (r.width >= 40 && r.height >= 40 && im.currentSrc && y < h && imgs.length < 16)
                    imgs.push({i: i, src: im.currentSrc, x: r.left, y: y, w: r.width, h: r.height});
            });
            const tiles = Math.max(1, Math.ceil(h / %d));
            b && (b.style.minHeight = ((tiles * %d + 4) / k) + 'px');
            return JSON.stringify({h: h, tiles: tiles, links: links, imgs: imgs});
        })()""" % (RENDER_W, RENDER_W, most, TILE, TILE)
        got = self.call("script.evaluate", {"expression": measure, "target": {"context": c}, "awaitPromise": False, "resultOwnership": "none"})
        info = json.loads(got["result"]["value"])
        # The GIFs that move are played by the island over the page: hidden from the photograph first, so a
        # transparent one does not show a frozen frame through its own.
        anims = moving_pictures(info.get("imgs", []))
        if anims:
            hide = json.dumps([a["i"] for a in anims])
            self.call("script.evaluate", {"expression": f"{hide}.forEach(i => document.images[i] && (document.images[i].style.visibility = 'hidden'))",
                                          "target": {"context": c}, "awaitPromise": False, "resultOwnership": "none"})
        tiles = []
        for k in range(info["tiles"]):
            # JPEG at 98: three times quicker to take than PNG and half the size, and as clean around small
            # coloured text (at 93 the words of a link wore a speckled halo).
            shot = self.call("browsingContext.captureScreenshot", {"context": c, "origin": "document", "format": {"type": "image/jpeg", "quality": 0.98},
                                                                   # 2 px taller than its step: it overlaps the next, so no seam shows where they meet.
                                                                   "clip": {"type": "box", "x": 0, "y": k * TILE, "width": RENDER_W, "height": TILE + 2}})
            path = os.path.join(CACHE, f"{stem}-x{round(scale * 100)}-{k}.jpg")
            with open(path + ".part", "wb") as f:
                f.write(base64.b64decode(shot["data"]))
            os.replace(path + ".part", path)
            tiles.append(path)
        self.used = time.time()
        return {"tiles": tiles, "h": info["h"], "links": info["links"], "cut": info["h"] >= most, "scale": scale, "anims": anims}


gifs = {}   # address → (path, width, height) of a GIF that moves, or None: asked once


def moving_pictures(imgs):
    """Of a page's pictures, the GIFs that move: fetched (once), kept in the cache, with where each sits."""
    def look(im):
        src = im["src"]
        if src in gifs:
            return gifs[src]
        path = src.split("?", 1)[0].lower()
        if path.endswith((".jpg", ".jpeg", ".png", ".webp", ".svg", ".avif")):
            return None
        try:
            if src.startswith("file://"):
                with open(src[7:], "rb") as f:
                    data = f.read(8_000_000)
            else:
                req = urllib.request.Request(src, headers={"User-Agent": "Mozilla/5.0 (X11; Linux x86_64)"})
                with urllib.request.urlopen(req, timeout=3) as r:
                    data = r.read(8_000_000)
        except Exception:
            return None
        # A GIF with more than one frame: each frame brings its own graphic control block.
        moving = data[:6] in (b"GIF87a", b"GIF89a") and data.count(b"\x21\xf9\x04") >= 2
        kept = keep_picture(data) if moving else None
        gifs[src] = (kept[0], kept[1][0], kept[1][1]) if kept else None
        return gifs[src]
    with concurrent.futures.ThreadPoolExecutor(6) as pool:
        found = list(pool.map(look, imgs))
    return [{"i": im["i"], "pic": g[0], "iw": g[1], "ih": g[2], "x": im["x"], "y": im["y"], "w": im["w"], "h": im["h"]}
            for im, g in zip(imgs, found) if g][:8]


def page_of(msg, uid):
    """The mail's HTML as a file Firefox can open: its pictures inside it pointed at, its scripts shut out."""
    part = msg.get_body(preferencelist=("html",))
    if part is None:
        return None
    try:
        content = part.get_content()
    except Exception:
        content = (part.get_payload(decode=True) or b"").decode("utf-8", "replace")
    os.makedirs(CACHE, exist_ok=True)
    for p in msg.walk():
        cid = (p.get("Content-ID") or "").strip("<> ")
        if cid and p.get_content_maintype() == "image":
            got = keep_picture(p.get_payload(decode=True) or b"")
            if got:
                content = content.replace("cid:" + cid, "file://" + got[0])
    guard = ('<meta charset="utf-8"><meta http-equiv="Content-Security-Policy" content="script-src \'none\'; object-src \'none\'; frame-src \'none\'">'
             '<base target="_blank"><style>html{scrollbar-width:none;background:#fff;color:#202124;font:14px/1.45 Arial,Helvetica,sans-serif}body{margin:16px 18px}img{max-width:100%;height:auto}</style>')
    content = re.sub(r"(?is)<script\b.*?</script>", "", content)
    html_doc = guard + content
    digest = hashlib.sha1(html_doc.encode("utf-8", "replace")).hexdigest()[:12]
    path = os.path.join(CACHE, f"page-{uid}-{digest}.html")
    with open(path, "w", encoding="utf-8") as f:
        f.write(html_doc)
    return path, f"render-{uid}-{digest}"


renders = queue.Queue()      # {"uid", "msg", "scale", "now"}: now = the one being looked at; else ahead of time
fox = Firefox()
rendered = {}                 # (uid, scale) → what it came to: asked again, told again at once


def render_worker():
    """One render at a time: the one being looked at first (the newest asked for), then the ones
    ahead of it in the list, made before they are needed; Firefox let go when idle."""
    now, ahead = None, []
    while True:
        try:
            item = renders.get(timeout=0 if (now or ahead) else 30)
        except queue.Empty:
            item = None
            if not (now or ahead):
                if fox.proc is not None and time.time() - fox.used > 180:
                    fox.stop()
                continue
        while item is not None:
            if item.get("warm"):
                if fox.proc is None or fox.proc.poll() is not None:
                    try:
                        fox.stop()
                        fox.start()
                        fox.used = time.time()
                    except Exception:
                        fox.stop()
            elif item.get("now"):
                now = item          # j/k went past the one before: only this one matters
            elif not any(a["uid"] == item["uid"] and a["scale"] == item["scale"] for a in ahead):
                ahead.append(item)
            try:
                item = renders.get_nowait()
            except queue.Empty:
                item = None
        if now:
            job, now = now, None
        elif ahead:
            job = ahead.pop(0)
        else:
            continue
        key = (job["uid"], job["scale"])
        if key in rendered:
            say({"t": "render", "uid": job["uid"], **rendered[key]})
            continue
        try:
            page = page_of(job["msg"], job["uid"])
            if page:
                out = fox.render(*page, scale=job["scale"])
                rendered[key] = out
                say({"t": "render", "uid": job["uid"], **out})
        except Exception as e:
            fox.stop()
            say({"t": "render", "uid": job["uid"], "scale": job["scale"], "error": str(e)[:200]})


# ── mails kept, and the ones ahead fetched before they are asked for ──

kept_msgs = {}                # uid → the message, the last few dozen
kept_lock = threading.Lock()


def keep(uid, msg):
    with kept_lock:
        kept_msgs[uid] = msg
        while len(kept_msgs) > 60:
            kept_msgs.pop(next(iter(kept_msgs)))


def get_message(conn, uid):
    with kept_lock:
        msg = kept_msgs.get(uid)
    if msg is None:
        msg = fetch_message(conn, uid)
        keep(uid, msg)
    return msg


def tell_body(uid, msg, web):
    """What the island needs to show it: its words now, and its render asked for (`web`)."""
    html = msg.get_body(preferencelist=("html",)) is not None
    blocks, left = blocks_of(msg, remote=False)
    say({"t": "body", "uid": uid, "blocks": blocks, "html": html, "full": not left})
    return html, left


ahead_q = queue.Queue()


def fetch_ahead():
    """On a connection of its own (the island's own requests never wait behind it): the mails
    next to the one open, fetched and rendered before j/k reaches them."""
    conn = None
    while True:
        uids, scale = ahead_q.get()
        while True:                     # only the latest list matters
            try:
                uids, scale = ahead_q.get_nowait()
            except queue.Empty:
                break
        for uid in uids:
            try:
                with kept_lock:
                    msg = kept_msgs.get(uid)
                if msg is None:
                    if conn is None:
                        conn = connect()
                    msg = fetch_message(conn, uid)
                    keep(uid, msg)
                    tell_body(uid, msg, True)
                if msg.get_body(preferencelist=("html",)) is not None and (uid, scale) not in rendered:
                    renders.put({"uid": uid, "msg": msg, "scale": scale, "now": False})
            except Exception:
                conn = None
            if not ahead_q.empty():
                break


# ── the two connections ─────────────────────────────────────────

jobs = queue.Queue()


def read_stdin():
    for line in sys.stdin:
        try:
            jobs.put(json.loads(line))
        except ValueError:
            pass
    jobs.put({"op": "quit"})


def watch():
    """IDLE on the inbox; whenever it moves, ask for the list again."""
    wait = 5
    while True:
        try:
            conn = connect()
            wait = 5
            while True:
                with conn.idle(duration=20 * 60) as idler:
                    for typ, _ in idler:
                        if typ in ("EXISTS", "EXPUNGE", "FETCH"):
                            jobs.put({"op": "refresh", "quiet": True})
                            break
                conn.noop()
        except Exception:
            time.sleep(wait)
            wait = min(wait * 2, 300)


def main():
    global ADDR, PW
    if not ADDR:
        say({"t": "state", "state": "nocreds", "msg": "Add your address and an app password to ~/.local/share/lumen/gmail.conf"})
        # Stay up, and start over by itself once they are there.
        while not credentials()[0]:
            time.sleep(5)
        os.execv(sys.executable, [sys.executable] + sys.argv)
    threading.Thread(target=read_stdin, daemon=True).start()
    threading.Thread(target=render_worker, daemon=True).start()
    threading.Thread(target=fetch_ahead, daemon=True).start()
    conn = None
    started_watch = False
    retry = 2                     # unreachable (no network yet at login): try again soon, then less often
    jobs.put({"op": "refresh"})
    while True:
        try:
            job = jobs.get(timeout=300 if conn else retry)
        except queue.Empty:
            job = {"op": "refresh", "quiet": True}
            if conn is None:
                retry = min(retry * 2, 60)
        op = job.get("op")
        if op == "quit":
            return
        # Changes come in bursts (a mail marked read, then moved): one list for all of them.
        if op == "refresh":
            time.sleep(0.15)
            while True:
                try:
                    nxt = jobs.get_nowait()
                except queue.Empty:
                    break
                if nxt.get("op") != "refresh":
                    jobs.put(nxt)
                    break
        for attempt in (0, 1):
            try:
                if conn is None:
                    conn = connect()
                    retry = 2
                    say({"t": "state", "state": "ok", "account": ADDR})
                    # Back after a failure on some other job: the list is still owed.
                    if op != "refresh":
                        jobs.put({"op": "refresh", "quiet": True})
                    if not started_watch:
                        threading.Thread(target=watch, daemon=True).start()
                        started_watch = True
                uid = job.get("uid")
                if op == "refresh":
                    conn.noop()
                    fetch_list(conn)
                elif op == "body":
                    msg = get_message(conn, uid)
                    # The large view shows an HTML mail as Firefox renders it: its pictures are Firefox's
                    # to fetch, not fetched twice for words that are only a stand-in should it fail.
                    web = bool(job.get("web")) and msg.get_body(preferencelist=("html",)) is not None
                    if web:
                        renders.put({"uid": uid, "msg": msg, "scale": job.get("scale", 1.0), "now": True})
                    html, left = tell_body(uid, msg, web)
                    if left and not web:
                        say({"t": "body", "uid": uid, "blocks": blocks_of(msg)[0], "html": html, "full": True})
                elif op == "render":
                    # Drawn again larger (the focused view), from the mail already kept.
                    msg = get_message(conn, uid)
                    if msg.get_body(preferencelist=("html",)) is not None:
                        renders.put({"uid": uid, "msg": msg, "scale": job.get("scale", 1.0), "now": True})
                elif op == "ahead":
                    ahead_q.put(([int(u) for u in job.get("uids", [])], job.get("scale", 1.0)))
                elif op == "warm":
                    renders.put({"warm": True})
                elif op == "seen":
                    conn.uid("STORE", str(uid), "+FLAGS" if job.get("v") else "-FLAGS", "(\\Seen)")
                elif op == "archive":
                    mid = message_id(conn, uid)
                    conn.uid("STORE", str(uid), "-X-GM-LABELS", "(\\Inbox)")
                    conn.expunge()
                    say({"t": "gone", "op": op, "uid": uid, "mid": mid})
                elif op == "trash":
                    mid = message_id(conn, uid)
                    conn.uid("MOVE", str(uid), trash_box(conn))
                    say({"t": "gone", "op": op, "uid": uid, "mid": mid})
                elif op == "restore":
                    restore(conn, job.get("mid", ""), job.get("was", "trash"))
                    say({"t": "done", "op": "restore", "uid": uid, "ok": True})
                    fetch_list(conn)
                elif op == "reply":
                    to = reply(conn, uid, job.get("text", ""))
                    say({"t": "done", "op": "reply", "uid": uid, "ok": True, "msg": "Sent to " + to})
                if op in ("seen", "archive", "trash"):
                    say({"t": "done", "op": op, "uid": uid, "ok": True})
                break
            except imaplib.IMAP4.error as e:
                text = str(e)
                if "AUTHENTICATIONFAILED" in text or "Invalid credentials" in text or "Application-specific password" in text:
                    say({"t": "state", "state": "auth", "msg": "Gmail refused the app password (in ~/.local/share/lumen/gmail.conf)"})
                    conn = None
                    time.sleep(30)
                    ADDR, PW = credentials()     # perhaps it has been put right meanwhile
                    jobs.put({"op": "refresh"})  # …and try again with it, without waiting to be asked
                    break
                conn = None
                if attempt:
                    say({"t": "done", "op": op, "uid": job.get("uid"), "ok": False, "msg": text[:200]})
            except smtplib.SMTPException as e:
                say({"t": "done", "op": op, "uid": job.get("uid"), "ok": False, "msg": "Could not send: " + str(e)[:160]})
                break
            except (OSError, imaplib.IMAP4.abort, RuntimeError) as e:
                conn = None
                if attempt:
                    if isinstance(e, RuntimeError):
                        say({"t": "done", "op": op, "uid": job.get("uid"), "ok": False, "msg": str(e)})
                    else:
                        say({"t": "state", "state": "offline", "msg": "Can't reach Gmail"})


def leave(*_):
    fox.stop()
    os._exit(0)


if __name__ == "__main__":
    # Asked to stop (lumen reloading, or going): Firefox and its profile go first.
    signal.signal(signal.SIGTERM, leave)
    signal.signal(signal.SIGINT, leave)
    signal.signal(signal.SIGHUP, leave)
    sweep_profiles()
    try:
        main()
    finally:
        fox.stop()
