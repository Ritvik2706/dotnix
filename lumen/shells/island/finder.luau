--!strict-off
--! The files: the island's file manager, in vim's keys, in the pill's card or
--! in a window of its own (`W`, Super+R). Everything here: walking the folders
--! (any of them, from / down), what is predicted you want next (AccessRank),
--! the search (names, kinds, dates, sizes, paths, and what is inside files),
--! thumbnails, the file operations with undo, and the keys.
--!
--! `require("finder")({ HOME = …, SCRIPTS = …, folder = …, wa_hook = … })`.

return function(sh)
local HOME, SCRIPTS, folder, wa_hook = sh.HOME, sh.SCRIPTS, sh.folder, sh.wa_hook

-- ── what files are ───────────────────────────────────────────────────
local function set_of(list) local t = {} for e in string.gmatch(list, "%S+") do t[e] = true end return t end
local EXT = {
    text = set_of("txt md markdown rst org log csv tsv json jsonc yaml yml toml ini conf cfg nix lua luau plm py rs go c h cpp hpp cc js ts tsx jsx mjs css scss html xml sh bash zsh fish vim sql tex bib java kt swift rb php r m wgsl glsl svelte vue gitignore env lock kdl zig hs ml ex exs el dart cs scala diff patch srt vtt"),
    image = set_of("png jpg jpeg jpe jfif gif webp bmp svg svgz avif heic heif jxl tif tiff ico tga psd xcf kra cr2 cr3 nef arw dng orf rw2 raf qoi jp2 exr"),
    video = set_of("mp4 mkv webm mov avi m4v mpg mpeg wmv flv 3gp ts mts m2ts ogv"),
    audio = set_of("mp3 flac ogg opus m4a wav aac wma alac aiff ape wv"),
    office = set_of("docx doc odt rtf pptx ppt odp xlsx xls ods odg pages key numbers"),
    sheet = set_of("xlsx xls ods csv tsv numbers"),
    slides = set_of("pptx ppt odp key"),
    archive = set_of("zip tar gz tgz xz txz zst bz2 tbz2 7z rar jar apk deb rpm whl cbz cbr"),
    font = set_of("ttf otf woff woff2 ttc"),
    book = set_of("epub mobi azw3 cbz cbr djvu"),
}
local THUMBABLE = {}
for _, k in ipairs({ "image", "video", "audio", "office", "font", "book", "text" }) do for e in pairs(EXT[k]) do THUMBABLE[e] = true end end
THUMBABLE.pdf, THUMBABLE.ai, THUMBABLE.eps, THUMBABLE.ps, THUMBABLE.xopp = true, true, true, true, true
local OFFICE_XML = { docx = "word/document.xml", pptx = "ppt/slides/slide1.xml", xlsx = "xl/sharedStrings.xml", odt = "content.xml", odp = "content.xml", ods = "content.xml" }

local function ext_of(path) return string.lower(string.match(path, "%.([%w]+)$") or "") end
local function tilde(p)
    if p == HOME then return "~" end
    if string.sub(p, 1, #HOME + 1) == HOME .. "/" then return "~" .. string.sub(p, #HOME + 1) end
    return p
end
local function untilde(p)
    if p == "~" then return HOME end
    if string.sub(p, 1, 2) == "~/" then return HOME .. string.sub(p, 2) end
    return p
end
local function join(dir, name) return dir == "/" and ("/" .. name) or (dir .. "/" .. name) end
local function parent_of(p)
    if p == "/" then return nil end
    local par = string.match(p, "^(.*)/[^/]+$")
    if par == "" then return "/" end
    return par
end
local function base_of(p) return p == "/" and "/" or (string.match(p, "([^/]+)$") or p) end
local function q(s) return "'" .. string.gsub(s, "'", "'\\''") .. "'" end
-- What a file is, in a word: what the search's kinds and the preview go by.
local function kind_of(e)
    if e.dir then return "folder" end
    local x = ext_of(e.path)
    if x == "pdf" then return "pdf" end
    for _, k in ipairs({ "image", "video", "audio", "office", "archive", "font", "book", "text" }) do
        if EXT[k][x] then return k end
    end
    return "other"
end

-- ── what is kept between sessions (finder.json) ──────────────────────
local store = (sys.ask("files.read", "finder.json", "json") or {})
store.pins = store.pins or {}         -- 1–9, in order (M)
store.marks = store.marks or {}       -- a–z → a folder (m a, ' a)
store.ar = store.ar or {}             -- AccessRank: see below
store.qmap = store.qmap or {}         -- what a search's first letters led to, as chosen
local saving = false
local function save()
    if saving then return end
    saving = true
    after(400, function() saving = false; pcall(sys.call, "files.write", "finder.json", store) end)
end

-- ── AccessRank (Fitchett & Cockburn, CHI 2012) ───────────────────────
-- Predicts what is opened next from what came before: a Markov chain (from
-- where you are, where you went next), every past visit counted and halved
-- with each ten later ones (CRF, p = 2, λ = 0.1), and the hour and weekday
-- you usually open it at. Score = markov^α · crf^(1/α) · time, α = 1.65.
-- Lists built from it keep their order unless a newcomer beats an incumbent
-- by 20 % (δ = 0.2), so the places stay where your hands learned them.
local AR = store.ar
AR.tick = AR.tick or 0
AR.items = AR.items or {}     -- path → { c = crf, l = last tick, n = visits, h = {24}, d = {7} }
AR.tr = AR.tr or {}           -- from → { to → n }   (what came next, wherever it was)
AR.trn = AR.trn or {}         -- from → n
AR.tw = AR.tw or {}           -- folder → { child → { n, c, l } }   (which way you went from a folder)
local ALPHA, DELTA = 1.65, 0.2
local function crf_now(c, l) return (c or 0) * math.pow(0.5, 0.1 * (AR.tick - (l or AR.tick))) end
local function time_weight(it)
    if not it or (it.n or 0) < 10 or not it.h or not it.d then return 1 end
    local now = os.date("*t")
    local hr = now.hour
    local h = ((it.h[((hr + 23) % 24) + 1] or 0) + (it.h[hr + 1] or 0) + (it.h[((hr + 1) % 24) + 1] or 0)) / math.max(1e-6, it.n / 8)
    local d = (it.d[now.wday] or 0) / math.max(1e-6, it.n / 7)
    return math.pow(math.clamp(h * d, 0.8, 1.25), 0.25)
end
local function ar_score(path, from)
    local it = AR.items[path]
    if not it then return 0 end
    local wm = 1
    if from then wm = (((AR.tr[from] or {})[path] or 0) + 1) / ((AR.trn[from] or 0) + 1) end
    return math.pow(wm, ALPHA) * math.pow(crf_now(it.c, it.l), 1 / ALPHA) * time_weight(it)
end
local function ar_prune()
    local n, list = 0, {}
    for p, it in pairs(AR.items) do n += 1; list[#list + 1] = { p = p, s = crf_now(it.c, it.l) } end
    if n <= 4000 then return end
    table.sort(list, function(a, b) return a.s > b.s end)
    for i = 3001, #list do
        local p = list[i].p
        AR.items[p] = nil; AR.tr[p] = nil; AR.trn[p] = nil; AR.tw[p] = nil
    end
end
local last_visit = nil
local function ar_visit(path, isdir)
    AR.tick += 1
    local it = AR.items[path] or { c = 0, l = AR.tick, n = 0, h = {}, d = {} }
    if isdir ~= nil then it.dir = isdir end
    if #it.h < 24 then for i = 1, 24 do it.h[i] = it.h[i] or 0 end end
    if #it.d < 7 then for i = 1, 7 do it.d[i] = it.d[i] or 0 end end
    it.c = crf_now(it.c, it.l) + 1
    it.l = AR.tick
    it.n += 1
    local now = os.date("*t")
    it.h[now.hour + 1] += 1
    it.d[now.wday] += 1
    AR.items[path] = it
    if last_visit and last_visit ~= path then
        AR.tr[last_visit] = AR.tr[last_visit] or {}
        AR.tr[last_visit][path] = (AR.tr[last_visit][path] or 0) + 1
        AR.trn[last_visit] = (AR.trn[last_visit] or 0) + 1
    end
    last_visit = path
    -- Every folder above it learns which way you went from there.
    local child, up = path, parent_of(path)
    while up do
        AR.tw[up] = AR.tw[up] or {}
        local w = AR.tw[up][child] or { n = 0, c = 0, l = AR.tick }
        w.c = crf_now(w.c, w.l) + 1
        w.l = AR.tick
        w.n += 1
        AR.tw[up][child] = w
        child, up = up, parent_of(up)
    end
    if AR.tick % 200 == 0 then ar_prune() end
    save()
end
-- Which of a folder's children you are most likely after (Icon Highlights, as keys:
-- the cursor lands on it). Only once it has been chosen at least twice.
local function ar_toward(dir)
    local ws = AR.tw[dir]
    if not ws then return {} end
    local total = 0
    for _, w in pairs(ws) do total += w.n end
    local list = {}
    for child, w in pairs(ws) do
        if w.n >= 2 then
            local s = math.pow((w.n + 1) / (total + 1), ALPHA) * math.pow(crf_now(w.c, w.l), 1 / ALPHA) * time_weight(AR.items[child])
            list[#list + 1] = { path = child, s = s }
        end
    end
    table.sort(list, function(a, b) return a.s > b.s end)
    return list
end
-- A ranked list that keeps its order: an incumbent keeps its place against a
-- newcomer unless that one is better by δ.
local function stable_rank(cands, previous)
    local was = {}
    for i, p in ipairs(previous or {}) do was[p] = i end
    for _, c in ipairs(cands) do if was[c.path] then c.s *= (1 + DELTA) end end
    table.sort(cands, function(a, b)
        if a.s ~= b.s then return a.s > b.s end
        return (was[a.path] or 1e9) < (was[b.path] or 1e9)
    end)
    return cands
end

-- ── icons and thumbnails ─────────────────────────────────────────────
local ficon = { mimes = {}, places = {}, MIMES = "/usr/share/icons/WhiteSur-dark/mimes/scalable/", PLACES = "/usr/share/icons/WhiteSur-dark/places/scalable/",
    folder = { downloads = "folder-download", documents = "folder-documents", pictures = "folder-pictures", videos = "folder-videos",
        music = "folder-music", desktop = "user-desktop", github = "folder-github", [".git"] = "folder-git", projects = "folder-projects",
        templates = "folder-templates", public = "folder-publicshare", code = "folder-code", src = "folder-code", scripts = "folder-script",
        custom_scripts = "folder-script", games = "folder-games", trash = "user-trash", files = "folder" },
    ext = { py = "text-x-python", rs = "text-x-rust", js = "text-x-javascript", mjs = "text-x-javascript", jsx = "text-x-javascript",
        ts = "text-x-typescript", tsx = "text-x-typescript", lua = "text-x-lua", luau = "text-x-lua", c = "text-x-csrc", h = "text-x-chdr",
        cpp = "text-x-c++src", cc = "text-x-c++src", hpp = "text-x-c++src", go = "text-x-go", java = "text-x-java", rb = "application-x-ruby",
        sh = "application-x-shellscript", bash = "application-x-shellscript", zsh = "application-x-shellscript", fish = "application-x-shellscript",
        md = "text-x-markdown", json = "application-json", yaml = "application-x-yaml", yml = "application-x-yaml", xml = "application-xml",
        html = "text-html", htm = "text-html", css = "text-css", scss = "text-x-scss", sass = "text-x-sass", txt = "text-x-generic",
        log = "text-x-log", patch = "text-x-patch", diff = "text-x-patch", pdf = "application-pdf", jpg = "image-jpeg", jpeg = "image-jpeg",
        svg = "image-svg+xml", doc = "x-office-document", docx = "x-office-document", odt = "x-office-document", rtf = "x-office-document",
        xls = "x-office-spreadsheet", xlsx = "x-office-spreadsheet", ods = "x-office-spreadsheet", csv = "x-office-spreadsheet",
        ppt = "x-office-presentation", pptx = "x-office-presentation", odp = "x-office-presentation", ttf = "font-x-generic",
        otf = "font-x-generic", woff = "font-x-generic", woff2 = "font-x-generic", zip = "application-zip", gz = "application-x-tar",
        tgz = "application-x-tar", xz = "application-x-tar", zst = "application-x-tar", bz2 = "application-x-tar", tar = "application-x-tar",
        ["7z"] = "application-zip", rar = "application-zip", mk = "text-x-makefile", nix = "text-x-generic", toml = "text-x-generic",
        ini = "text-x-generic", conf = "text-x-generic", cfg = "text-x-generic", plm = "text-x-generic", epub = "application-epub+zip" } }
run("find", { ficon.MIMES, ficon.PLACES, "-maxdepth", "1", "-name", "*.svg" }, function(out)
    for path in string.gmatch(out or "", "[^\n]+") do
        local dir, name = string.match(path, "^(.*/)([^/]+)%.svg$")
        if dir == ficon.MIMES then ficon.mimes[name] = true elseif dir == ficon.PLACES then ficon.places[name] = true end
    end
end)
function ficon.of(name, isdir, path)
    if isdir then
        local special = ficon.folder[string.lower(name)]
        if path == HOME then special = "user-home" end
        return ficon.PLACES .. ((special and ficon.places[special]) and special or "folder") .. ".svg"
    end
    local x = ext_of(path or name)
    local generic = (EXT.image[x] and "image-x-generic") or (x == "pdf" and "application-pdf") or (EXT.video[x] and "video-x-generic")
        or (EXT.audio[x] and "audio-x-generic") or (EXT.archive[x] and "package-x-generic") or "text-x-generic"
    for _, n in ipairs({ ficon.ext[x] or "", "image-" .. x, "video-" .. x, "audio-" .. x, "application-x-" .. x, "text-x-" .. x, generic }) do
        if n ~= "" and ficon.mimes[n] then return ficon.MIMES .. n .. ".svg" end
    end
    return ficon.MIMES .. "text-x-generic.svg"
end

-- Thumbnails: made by scripts/thumbd.sh (three of them, side by side), kept in
-- ~/.cache/lumen/thumbs by path, time and size, so each is only ever made once.
-- The ones in sight are asked for first; leaving a folder drops what was queued.
local THUMBS = HOME .. "/.cache/lumen/thumbs"
run("mkdir", { "-p", THUMBS }, nil, { output = false })
local thumb = { known = {}, queue = {}, queued = {}, busy = {}, workers = {}, failed = {} }
-- known: key → { path, ar } (made) · failed: key → true
thumb.index = (sys.ask("files.read", "thumbs.json", "json") or {})
for k, v in pairs(thumb.index) do thumb.known[k] = v end
local function hash(s)
    local h1, h2 = 5381, 52711
    for i = 1, #s do
        local c = string.byte(s, i)
        h1 = (h1 * 33 + c) % 4294967296
        h2 = (h2 * 31 + c) % 4294967296
    end
    return string.format("%08x%08x", h1, h2)
end
local function thumb_key(e) return hash(e.path) .. "-" .. math.floor(e.mtime or 0) .. "-" .. (e.size or 0) end
local thumb_changed, thumb_save_due = nil, false
local function thumb_save()
    if thumb_save_due then return end
    thumb_save_due = true
    after(3000, function() thumb_save_due = false; pcall(sys.call, "files.write", "thumbs.json", thumb.index) end)
end
local thumb_pump
local function thumb_worker(k)
    if thumb.workers[k] then return thumb.workers[k] end
    local id
    id = spawn(SCRIPTS .. "thumbd.sh", {}, function(line)
        local ok, out, w, h = string.match(line, "^(%a+)\t([^\t]+)\t?(%d*)\t?(%d*)")
        local key = out and string.match(out, "([^/]+)%.png$")
        if not key then return end
        thumb.busy[key] = nil
        if ok == "ok" and tonumber(w) and tonumber(h) and tonumber(h) > 0 then
            local v = { p = out, ar = tonumber(w) / tonumber(h) }
            thumb.known[key] = v
            thumb.index[key] = v
            thumb_save()
            if thumb_changed then thumb_changed() end
        else
            thumb.failed[key] = true
        end
        thumb_pump()
    end, function() thumb.workers[k] = nil end, { stdin = "open" })
    thumb.workers[k] = id
    return id
end
local thumb_load = { 0, 0, 0 }
thumb_pump = function()
    for k = 1, 3 do
        thumb_load[k] = 0
    end
    local inflight = 0
    for _ in pairs(thumb.busy) do inflight += 1 end
    while inflight < 6 and #thumb.queue > 0 do
        local job = table.remove(thumb.queue, 1)
        thumb.queued[job.key] = nil
        if not thumb.known[job.key] and not thumb.busy[job.key] and not thumb.failed[job.key] then
            -- Office documents may need LibreOffice (seconds): always the third worker, so pictures never wait behind them.
            local k = EXT.office[ext_of(job.path)] and 3 or ((inflight % 2) + 1)
            local id = thumb_worker(k)
            if id and write(id, job.path .. "\t" .. THUMBS .. "/" .. job.key .. ".png\t256\n") then
                thumb.busy[job.key] = true
                inflight += 1
            end
        end
    end
end
-- The picture to show for an entry (and its shape), or its icon; asks for one if it can be made.
local function picture_of(e, urgent)
    if e.dir or not e.mtime then return nil, 0 end
    local x = ext_of(e.path)
    if not THUMBABLE[x] then return nil, 0 end
    if (e.size or 0) > 4e9 then return nil, 0 end
    local key = thumb_key(e)
    local v = thumb.known[key]
    if v then return v.p, v.ar end
    if not thumb.failed[key] and not thumb.busy[key] and not thumb.queued[key] then
        thumb.queued[key] = true
        local job = { key = key, path = e.path }
        if urgent then table.insert(thumb.queue, 1, job) else thumb.queue[#thumb.queue + 1] = job end
    end
    return nil, 0
end

-- ── the state ────────────────────────────────────────────────────────
local S = {
    cwd = HOME,          -- the folder showing
    entries = {},        -- what is in it (as read)
    view = {},           -- what is listed: the folder (sorted, filtered) or a search's results
    sel = 0, off = 0,    -- the cursor, and the first row in sight
    mode = "dir",        -- "dir" | "jump" (a search's results) | "with" (Open With's apps)
    filter = "",         -- `/`: narrowing the folder
    hidden = store.hidden == true,
    sort_i = 1, sort_rev = false,
    grid = store.grid == true,
    marked = {}, nmarks = 0,
    visual = nil,        -- v: where the range started
    reg = nil,           -- yy / dd: { mode = "copy" | "cut", paths, set }
    back = {}, fwd = {}, -- the folders walked through (H L, Ctrl+o)
    prev_dir = nil,      -- '' : the folder before this one
    cursor = {},         -- folder → the path the cursor was last on there
    undo = {},
    pre = nil,           -- a key waiting for its second (g, y, d, m, ', f, z)
    open = false,        -- showing (the card or the window)
    monitor = nil,       -- gio monitor's id, watching the folder
    rail_prev = {},      -- the suggested places as last listed (for their stability)
    jump_prev = {},
    last_f = nil,        -- f's letter, for ; and ,
    rows = 14, cols = 1,
    free = "",
    loading = false,
}
local SORTS = { "name", "modified", "size", "type" }
local SORT_LABEL = { name = "Name", modified = "Modified", size = "Size", type = "Kind" }
S.sort_i = table.find(SORTS, store.sort or "name") or 1
S.sort_rev = store.sort_rev == true
fact.fnd_grid = S.grid
fact.fnd_pv_on = store.preview ~= false
fact.pvd_list = store.pv_view == "list"

local function toast(msg) text.fnd_toast = msg; fact.fnd_toast_seq = (fact.fnd_toast_seq or 0) + 1 end
local function n_items(n) return n == 1 and "1 item" or (n .. " items") end
local function human(bytes)
    bytes = tonumber(bytes) or 0
    if bytes < 1024 then return bytes .. " B" end
    if bytes < 1048576 then return string.format("%.0f KB", bytes / 1024) end
    if bytes < 1073741824 then return string.format("%.1f MB", bytes / 1048576) end
    return string.format("%.1f GB", bytes / 1073741824)
end
local function when(t)
    t = tonumber(t)
    if not t then return "" end
    local d = os.time() - t
    if d < 60 then return "now" end
    if d < 3600 then return math.floor(d / 60) .. " min" end
    if d < 86400 then return math.floor(d / 3600) .. " h" end
    if d < 7 * 86400 then return math.floor(d / 86400) .. " d" end
    if os.date("%Y", t) == os.date("%Y") then return os.date("%d %b", t) end
    return os.date("%b %Y", t)
end

-- An entry: a path, and what is known of it.
local function norm(x) return (string.gsub(x, "[%s_%-%.]+", " ")) end
local function entry(path, dir, size, mtime, link)
    local name = base_of(path)
    local low = string.lower(name)
    return { path = path, name = name, low_name = low, n_name = norm(low), parent = parent_of(path) or "/", dir = dir, size = size, mtime = mtime, link = link }
end

-- Natural order ("file2" before "file10"), as Thunar sorts.
local function natural_less(a, b)
    local i, j = 1, 1
    while i <= #a and j <= #b do
        local da, db = string.match(a, "^%d+", i), string.match(b, "^%d+", j)
        if da and db then
            local na, nb = tonumber(da), tonumber(db)
            if na ~= nb then return na < nb end
            i += #da; j += #db
        else
            local ca, cb = string.sub(a, i, i), string.sub(b, j, j)
            if ca ~= cb then return ca < cb end
            i += 1; j += 1
        end
    end
    return #a - i < #b - j
end

-- ── the index (for the search): everything under ~ that is not ignored ──
-- fd writes all of home to a file in ~30 ms (.gitignore'd output, hidden files,
-- caches and Go's module store left out; folders end in /), plus ~/.config two
-- deep; and a second file holds what is outside it that you have opened and
-- zoxide's folders. The logic never holds it: a search hands it to fzf, which
-- ranks 37k paths in ~20 ms, and only its best few hundred come back here to be
-- ranked again by what is yours (AccessRank, what you chose before, zoxide).
local IX = { at = 0, busy = false, file = folder .. "/index.txt", extra = folder .. "/index-extra.txt", dirs = folder .. "/index-dirs.txt" }
local zox = {}
local function index(after_)
    if IX.busy then return end
    IX.busy = true
    local ex = "-E node_modules -E .cache -E target -E .git -E __pycache__ -E .venv -E venv -E go/pkg"
    local script = "fd -a --color never -t f -t d -t l " .. ex .. " . \"$1\" > \"$2.new\"; "
        .. "fd -a --color never -H -d 2 " .. ex .. " . \"$1/.config\" >> \"$2.new\"; "
        .. "mv \"$2.new\" \"$2\"; grep '/$' \"$2\" > \"$3\""
    run("sh", { "-c", script, "sh", HOME, IX.file, IX.dirs }, function()
        -- Outside the index: what was opened elsewhere, zoxide's folders.
        local lines = {}
        for p, it in pairs(AR.items) do
            if string.sub(p, 1, #HOME + 1) ~= HOME .. "/" then lines[#lines + 1] = p .. (it.dir and "/" or "") end
        end
        for p in pairs(zox) do if string.sub(p, 1, #HOME + 1) ~= HOME .. "/" then lines[#lines + 1] = p .. "/" end end
        run("tee", { IX.extra }, function()
            IX.at, IX.busy = os.time(), false
            if after_ then after_() end
        end, { input = table.concat(lines, "\n") .. "\n" })
    end)
end
-- The best `n` of the index (folders only: `dirs`) for these words, in fzf's order.
local function fzf_rank(words, dirs, n, then_)
    local q = table.concat(words, " ")
    local src = dirs and ('grep "/$" "$3" | cat "$2" -') or 'cat "$2" "$3"'
    run("sh", { "-c", src .. ' 2>/dev/null | fzf --filter "$1" --scheme=path | head -n ' .. n, "sh", q, dirs and IX.dirs or IX.file, IX.extra }, function(out)
        local list = {}
        for l in string.gmatch(out or "", "[^\n]+") do
            local isdir = string.sub(l, -1) == "/"
            local p = isdir and #l > 1 and string.sub(l, 1, -2) or l
            list[#list + 1] = entry(p, isdir)
        end
        then_(list)
    end)
end
-- Whether a path is a folder, as far as is known without asking the disk.
local function is_dir(p)
    local it = AR.items[p]
    if it and it.dir ~= nil then return it.dir end
    return not string.find(base_of(p), "%.%w+$")
end
run("zoxide", { "query", "-l", "-s" }, function(out)
    for l in string.gmatch(out or "", "[^\n]+") do
        local s, p = string.match(l, "^%s*([%d%.]+)%s+(.+)$")
        if p then zox[p] = tonumber(s) end
    end
end)

-- ── the places on the left (the rail) ────────────────────────────────
local PLACES = {
    { "Home", HOME, "gh" }, { "Desktop", HOME .. "/Desktop", "" }, { "Documents", HOME .. "/Documents", "gD" },
    { "Downloads", HOME .. "/Downloads", "gd" }, { "Pictures", HOME .. "/Pictures", "gp" }, { "Videos", HOME .. "/Videos", "gv" },
    { "Music", HOME .. "/Music", "gm" }, { "github", HOME .. "/github", "gr" }, { "Trash", HOME .. "/.local/share/Trash/files", "gt" },
}
local places_here = {}
local drives = {}
local rail_paths = {}
local function exists_dir(p, f) run("test", { "-d", p }, function(_, code) f(code == 0) end) end
for _, pl in ipairs(PLACES) do
    exists_dir(pl[2], function(yes) places_here[pl[2]] = yes end)
end
-- Drives: what is plugged in (and mounted, or can be: a click mounts it).
local function read_drives(then_)
    run("lsblk", { "-J", "-o", "PATH,LABEL,SIZE,MOUNTPOINT,HOTPLUG,TYPE,FSTYPE,RM" }, function(out)
        local ok, t = pcall(json.decode, out or "")
        local list = {}
        local function walk(devs)
            for _, d in ipairs(devs or {}) do
                local mp = d.mountpoint
                local hot = d.hotplug == true or d.hotplug == "1" or d.rm == true or d.rm == "1"
                local mounted_media = type(mp) == "string" and (string.find(mp, "^/run/media/") or string.find(mp, "^/media/") or string.find(mp, "^/mnt/"))
                if (d.type == "part" or d.type == "disk") and d.fstype and d.fstype ~= json.null and d.fstype ~= "swap" and (hot or mounted_media) then
                    local label = (type(d.label) == "string" and d.label ~= "") and d.label or (tostring(d.size or "") .. " drive")
                    list[#list + 1] = { name = label, dev = d.path, mount = type(mp) == "string" and mp or nil }
                end
                walk(d.children)
            end
        end
        if ok and t then walk(t.blockdevices) end
        drives = list
        if then_ then then_() end
    end)
end

-- ── showing it ───────────────────────────────────────────────────────
local preview, show
local function sort_entries(list)
    local key = SORTS[S.sort_i]
    table.sort(list, function(a, b)
        if a.dir ~= b.dir then return a.dir end
        local x, y
        if key == "modified" then
            if (a.mtime or 0) ~= (b.mtime or 0) then
                if S.sort_rev then return (a.mtime or 0) < (b.mtime or 0) end
                return (a.mtime or 0) > (b.mtime or 0)
            end
        elseif key == "size" then
            if (a.size or 0) ~= (b.size or 0) then
                if S.sort_rev then return (a.size or 0) < (b.size or 0) end
                return (a.size or 0) > (b.size or 0)
            end
        elseif key == "type" then
            x, y = ext_of(a.path), ext_of(b.path)
            if x ~= y then if S.sort_rev then return x > y end return x < y end
        end
        if S.sort_rev and key == "name" then return natural_less(b.low_name, a.low_name) end
        return natural_less(a.low_name, b.low_name)
    end)
end

-- How well one word matches an entry: in its name first (at its start best),
-- then anywhere in its path, then as letters in order in its name (fuzzy).
-- Spaces, `_`, `-` and `.` are alike: "boarding pass" finds boarding_pass.pdf.
local function word_score(e, w)
    local a = string.find(e.n_name, w, 1, true)
    if a then
        local start = a == 1 or string.sub(e.n_name, a - 1, a - 1) == " "
        return (a == 1 and 150 or start and 125 or 100) - #e.n_name * 0.15
    end
    local np = e.n_path or norm(string.lower(tilde(e.path)))
    if string.find(np, w, 1, true) then return 55 - #np * 0.03 end
    local pos, gaps, last = 1, 0, 0
    for i = 1, #w do
        local f = string.find(e.n_name, string.sub(w, i, i), pos, true)
        if not f then return nil end
        if last > 0 then gaps += f - last - 1 end
        last, pos = f, f + 1
    end
    if gaps > #w * 2 then return nil end
    return 30 - gaps
end
local function fuzzy(e, words)
    local total = 0
    for _, w in ipairs(words) do
        local sc = word_score(e, w)
        if not sc then return nil end
        total += sc
    end
    return total
end

-- What a row shows, inside a folder or as a search's result.
local function row_of(e, i, listing, marked_paths, cell)
    local pic, ar = picture_of(e, true)
    local badge = ""
    for k, p in ipairs(store.pins) do if p == e.path then badge = tostring(k) end end
    for l, p in pairs(store.marks) do if p == e.path and badge == "" then badge = l end end
    local size = (not e.dir and e.size) and human(e.size) or ""
    local sub = ""
    if not listing then
        sub = e.snippet or tilde(e.parent)
    end
    return {
        name = e.name, sub = sub, ic = pic or ficon.of(e.name, e.dir, e.path), ar = pic and ar or 0,
        size = size, date = when(e.mtime), sel = (i - 1) == S.sel, mark = S.marked[e.path] == true,
        cut = S.reg ~= nil and S.reg.mode == "cut" and S.reg.set[e.path] == true, badge = badge, hasb = badge ~= "",
        hint = e.hint == true, dir = e.dir == true, head = e.head == true, link = e.link == true,
        target = S.reg ~= nil and (i - 1) == S.sel and e.dir == true and S.mode == "dir",
        drag = (S.marked[e.path] and S.nmarks > 1) and marked_paths or e.path,
    }
end

-- The breadcrumb: / or ~, then each folder down to this one; a long way down keeps
-- the first, an … and the last two. Each crumb takes you there.
local crumb_paths = {}
local function crumbs()
    local list = {}
    local p = S.cwd
    local inhome = p == HOME or string.sub(p, 1, #HOME + 1) == HOME .. "/"
    local base = inhome and HOME or "/"
    list[1] = { name = inhome and "~" or "/", path = base }
    local rest = inhome and string.sub(p, #HOME + 2) or string.sub(p, 2)
    local acc = base
    for seg in string.gmatch(rest, "[^/]+") do
        acc = join(acc, seg)
        list[#list + 1] = { name = seg, path = acc }
    end
    if S.mode == "jump" then list = { { name = "Search", path = false } } end
    if S.mode == "with" then list = { { name = "Open With", path = false } } end
    if S.mode == "dest" then list = { { name = (S.reg and S.reg.mode == "copy") and "Copy to…" or "Move to…", path = false } } end
    if #list > 5 then
        local n = #list
        list = { list[1], { name = "…", path = list[n - 2].path }, list[n - 1], list[n] }
    end
    local rows = {}
    crumb_paths = {}
    for i, c in ipairs(list) do
        local name = c.name
        if utf8.len(name) and utf8.len(name) > 26 then name = string.sub(name, 1, utf8.offset(name, 25) - 1) .. "…" end
        rows[i] = { name = name, last = i == #list }
        crumb_paths[i] = c.path
    end
    model.fcrumbs = rows
end

-- The rail: pinned (1–9) and marked (a–z), what AccessRank suggests from here,
-- the places, the drives.
local function rail()
    local rows = {}
    rail_paths = {}
    local function add(r, path) rows[#rows + 1] = r; rail_paths[#rows] = path end
    local function item(name, path, ic, badge, kind)
        add({ name = name, ic = ic, badge = badge or "", hasb = (badge or "") ~= "", head = false, at = path == S.cwd and S.mode == "dir", kind = kind or 0 }, path)
    end
    local any = false
    for k, p in ipairs(store.pins) do
        if k <= 9 then
            if not any then add({ name = "Pinned", head = true }, false); any = true end
            item(base_of(p) == "" and p or base_of(p), p, ficon.of(base_of(p), true, p), tostring(k))
        end
    end
    local letters = {}
    for l in pairs(store.marks) do letters[#letters + 1] = l end
    table.sort(letters)
    for _, l in ipairs(letters) do
        local p = store.marks[l]
        if not any then add({ name = "Pinned", head = true }, false); any = true end
        item(base_of(p), p, ficon.of(base_of(p), true, p), "'" .. l)
    end
    -- Suggested: where you usually go from here (folders only; files are the search's).
    local cands, seen = {}, {}
    for _, p in ipairs(store.pins) do seen[p] = true end
    for _, p in pairs(store.marks) do seen[p] = true end
    for p, it in pairs(AR.items) do
        if not seen[p] and p ~= S.cwd and (it.n or 0) >= 2 and is_dir(p) then
            cands[#cands + 1] = { path = p, s = ar_score(p, S.cwd) }
        end
    end
    stable_rank(cands, S.rail_prev)
    S.rail_prev = {}
    local shown = 0
    for _, c in ipairs(cands) do
        if shown >= 5 then break end
        if shown == 0 then add({ name = "Suggested", head = true }, false) end
        shown += 1
        S.rail_prev[shown] = c.path
        item(base_of(c.path), c.path, ficon.of(base_of(c.path), true, c.path), "", 1)
    end
    add({ name = "Places", head = true }, false)
    for _, pl in ipairs(PLACES) do
        if places_here[pl[2]] then item(pl[1], pl[2], ficon.of(pl[1] == "Home" and "home" or pl[1], true, pl[2]), "", 0) end
    end
    if #drives > 0 then
        add({ name = "Drives", head = true }, false)
        for _, d in ipairs(drives) do
            add({ name = d.name, ic = ficon.PLACES .. (ficon.places["drive-removable-media"] and "drive-removable-media" or "folder") .. ".svg", badge = d.mount and "" or "⏏", hasb = not d.mount, head = false, at = d.mount == S.cwd, kind = 2 }, { drive = d })
        end
    end
    model.frail = rows
end

-- What is in sight: the rows (or the grid's cells) around the cursor.
local function in_sight()
    local n = #S.view
    S.sel = math.clamp(S.sel, 0, math.max(0, n - 1))
    if S.grid and S.mode == "dir" then
        local cols = math.max(1, S.cols)
        local rows = math.max(1, S.grows or 3)
        local row, top = S.sel // cols, S.off // cols
        if row < top then top = row end
        if row >= top + rows then top = row - rows + 1 end
        S.off = math.clamp(top, 0, math.max(0, (n - 1) // cols - rows + 1)) * cols
        return S.off, math.min(n, S.off + cols * rows)
    end
    local rows = math.max(1, S.mode == "dir" and S.rows or S.jrows)
    if S.sel < S.off then S.off = S.sel end
    if S.sel >= S.off + rows then S.off = S.sel - rows + 1 end
    S.off = math.clamp(S.off, 0, math.max(0, n - rows))
    return S.off, math.min(n, S.off + rows)
end

local function status_line()
    if S.mode == "jump" then
        local n = #S.view
        return (n == 0 and "No matches" or (n .. (n == 1 and " match" or " matches"))) .. (S.content_busy and " · looking inside files…" or "")
    end
    if S.mode == "with" then return "Choose an application · Enter opens · Esc back" end
    if S.mode == "dest" then return "Where it usually goes first · type to find any folder · Enter puts it there · Tab goes there · Esc back" end
    local nd, nf, bytes = 0, 0, 0
    for _, e in ipairs(S.view) do if e.dir then nd += 1 else nf += 1; bytes += (e.size or 0) end end
    local parts = {}
    if nd > 0 then parts[#parts + 1] = nd .. (nd == 1 and " folder" or " folders") end
    if nf > 0 then parts[#parts + 1] = nf .. (nf == 1 and " file" or " files") .. " · " .. human(bytes) end
    if #parts == 0 then parts[1] = S.loading and "Reading…" or "Empty" end
    if S.nmarks > 0 then
        local mb = 0
        for p in pairs(S.marked) do local e = S.by_path and S.by_path[p]; if e and not e.dir then mb += (e.size or 0) end end
        parts[#parts + 1] = S.nmarks .. " marked" .. (mb > 0 and (" · " .. human(mb)) or "")
    end
    if S.free ~= "" then parts[#parts + 1] = S.free .. " free" end
    if S.filter ~= "" then table.insert(parts, 1, "/" .. S.filter) end
    return table.concat(parts, "  ·  ")
end

show = function()
    -- v: the range from where it started to the cursor, however the cursor got there (j k, G, gg, f…).
    if S.visual then
        S.visual = math.clamp(S.visual, 0, math.max(0, #S.view - 1))
        S.marked, S.nmarks = {}, 0
        for k = math.min(S.visual, S.sel), math.max(S.visual, S.sel) do
            local e = S.view[k + 1]
            if e and not e.head then S.marked[e.path] = true; S.nmarks += 1 end
        end
    end
    local listing = S.mode == "dir"
    fact.fnd_mode = listing and 0 or ((S.mode == "jump" or S.mode == "dest") and 1 or 2)
    local from, to = in_sight()
    crumbs()
    local marked_paths = ""
    if S.nmarks > 1 then
        local list = {}
        for pth in pairs(S.marked) do list[#list + 1] = pth end
        table.sort(list)
        marked_paths = table.concat(list, "\n")
    end
    local rows = {}
    for i = from + 1, to do rows[#rows + 1] = row_of(S.view[i], i, listing, marked_paths) end
    model.fhits = rows
    local at = -1
    for k, x in ipairs(rows) do if x.sel then at = k - 1 end end
    fact.fnd_at = at
    fact.fnd_count = #S.view
    fact.fnd_first = from
    text.fnd_sort = SORT_LABEL[SORTS[S.sort_i]] .. (S.sort_rev and " ↓" or " ↑")
    fact.fnd_marks = S.nmarks
    fact.fnd_visual = S.visual ~= nil
    fact.fnd_filtering = S.filter ~= ""
    text.fnd_status = status_line()
    if S.carry_show then S.carry_show() end
    text.fnd_title = S.mode == "jump" and "Search" or (S.mode == "with" and "Open With" or tilde(S.cwd))
    rail()
    -- Thumbnails just under what is in sight come next, so scrolling finds them made.
    if listing then
        for i = to + 1, math.min(#S.view, to + 24) do picture_of(S.view[i], false) end
    end
    thumb_pump()
    -- The preview follows the cursor: drawn again only when what is chosen changes (a thumbnail
    -- arriving, a mark, a sort must not restart a page being drawn or a video playing).
    local cur = S.view[S.sel + 1]
    local key = cur and (cur.path or "") .. (cur.head and "#" or "") or ""
    if key ~= S.pv_for then S.pv_for = key; preview(cur) end
end
-- A thumbnail arrived: what is in sight is drawn again (once per frame's worth of them).
local redraw_due = false
thumb_changed = function()
    if S.on_thumb then S.on_thumb() end
    if S.pvd_fill then S.pvd_fill() end
    if not S.open or redraw_due then return end
    redraw_due = true
    after(60, function() redraw_due = false; if S.open then show() end end)
end

-- ── reading a folder ─────────────────────────────────────────────────
local function apply_filter()
    local list = {}
    if S.filter == "" then
        for _, e in ipairs(S.entries) do if S.hidden or string.sub(e.name, 1, 1) ~= "." then list[#list + 1] = e end end
        sort_entries(list)
    else
        local words = {}
        for w in string.gmatch(norm(string.lower(S.filter)), "%S+") do words[#words + 1] = w end
        local scored = {}
        for _, e in ipairs(S.entries) do
            if S.hidden or string.sub(e.name, 1, 1) ~= "." or string.sub(S.filter, 1, 1) == "." then
                local s = fuzzy(e, words)
                if s then scored[#scored + 1] = { e = e, s = s + ar_score(e.path, S.cwd) * 8 } end
            end
        end
        table.sort(scored, function(a, b) return a.s > b.s end)
        for i, x in ipairs(scored) do list[i] = x.e end
    end
    -- Icon Highlights: what you are likely after here wears a dot.
    local hints = {}
    for k, c in ipairs(ar_toward(S.cwd)) do if k <= 3 then hints[c.path] = true end end
    for _, e in ipairs(list) do e.hint = hints[e.path] == true end
    S.view = list
end
local function watch_folder(dir)
    if S.monitor then kill(S.monitor); S.monitor = nil end
    if not S.open then return end
    local due = false
    S.monitor = spawn("gio", { "monitor", dir }, function(line)
        if due or S.cwd ~= dir then return end
        -- (attribute changes alone, e.g. a file being read, are not changes to the list)
        if string.find(line, "attributes changed", 1, true) then return end
        due = true
        after(150, function()
            due = false
            if S.cwd == dir and S.open then
                local keep = S.view[S.sel + 1] and S.view[S.sel + 1].path
                S.reload(keep)
            end
        end)
    end, nil)
end
-- What is in a folder, with sizes and times (and whether a link leads to a folder), in one `find`.
local function load(dir, then_)
    S.loading = true
    run("find", { dir, "-mindepth", "1", "-maxdepth", "1", "-printf", "%y%Y\t%s\t%T@\t%f\n" }, function(out, code)
        S.loading = false
        if S.cwd ~= dir then return end
        local list, by = {}, {}
        for l in string.gmatch(out or "", "[^\n]+") do
            local y, ty, size, t, name = string.match(l, "^(%a)(%a)\t(%d+)\t([%d%.]+)\t(.+)$")
            if name then
                local e = entry(join(dir, name), ty == "d", tonumber(size), tonumber(t), y == "l")
                list[#list + 1] = e
                by[e.path] = e
            end
        end
        if code ~= 0 and #list == 0 then toast("Can't read " .. tilde(dir)) end
        S.entries, S.by_path = list, by
        apply_filter()
        if then_ then then_() end
    end)
    run("df", { "-h", "--output=avail", dir }, function(out)
        local v = string.match(out or "", "\n%s*(%S+)")
        if v and S.cwd == dir then S.free = v .. "B"; text.fnd_status = status_line() end
    end)
end
-- After a change on disk: the folder read again, the cursor on `keep` (a path) if it is still there.
function S.reload(keep)
    if S.mode ~= "dir" then return end
    S.pv_for = nil
    load(S.cwd, function()
        if keep then for i, e in ipairs(S.view) do if e.path == keep then S.sel = i - 1 end end end
        show()
    end)
end

-- To a folder: the cursor on `want`, else where it was last time, else on what you
-- usually go to from there (once that is known), else the first.
local function note_cursor()
    local e = S.view[S.sel + 1]
    if e and S.mode == "dir" and S.filter == "" then S.cursor[S.cwd] = e.path end
end
local function go(dir, want, how)
    if not dir then return end
    dir = untilde(dir)
    if #dir > 1 then dir = string.gsub(dir, "/+$", "") end
    if how ~= "history" and dir ~= S.cwd then
        note_cursor()
        table.insert(S.back, S.cwd)
        if #S.back > 100 then table.remove(S.back, 1) end
        S.fwd = {}
    elseif how == "history" then
        note_cursor()
    end
    if dir ~= S.cwd then S.prev_dir = S.cwd end
    S.cwd = dir
    S.mode = "dir"
    S.filter = ""
    S.visual = nil
    S.free = ""
    text.fq = ""
    fact.fq_empty = true
    fact.fnd_insert = false
    S.sel, S.off = 0, 0
    S.entries, S.view = {}, {}
    thumb.queue, thumb.queued = {}, {}
    watch_folder(dir)
    load(dir, function()
        local target = want or S.cursor[dir]
        if not target then
            local guess = ar_toward(dir)[1]
            if guess then target = guess.path end
        end
        if target then for i, e in ipairs(S.view) do if e.path == target then S.sel = i - 1 end end end
        show()
    end)
    if how ~= "quiet" then
        ar_visit(dir, true)
        run("zoxide", { "add", dir }, nil, { output = false })
    end
end
S.go = go

-- ── the preview ──────────────────────────────────────────────────────
-- (Text and code as written, pictures fitted, a PDF's or a video's first page or
-- frame, a document's words then its page, an archive's list, a song's cover, a
-- font's sheet, a folder's contents.)
local VW, VH = 624, 400
local pv_gen, pv_slot = 0, 0
local pic_w, pic_h = 16, 9
local function fit_pic(w, h)
    w, h = tonumber(w) or 16, tonumber(h) or 9
    pic_w, pic_h = w, h
    local k = math.min(VW / w, VH / h, 2)
    fact.pv_iw = math.max(40, math.floor(w * k + 0.5))
    fact.pv_ih = math.max(30, math.floor(h * k + 0.5))
    fact.pv_cs = (w * k) / (w * math.min(624 / w, 400 / h))
end
local PV = { z = 1, px = 0, py = 0, doc = false }
local function pv_view()
    local mx = math.max(0, (fact.pv_iw * PV.z - VW) / 2)
    local my = math.max(0, (fact.pv_ih * PV.z - VH) / 2)
    PV.px, PV.py = math.clamp(PV.px, -mx, mx), math.clamp(PV.py, -my, my)
    fact.pv_z, fact.pv_px, fact.pv_py = PV.z, PV.px, PV.py
    text.pv_zoom = math.floor(PV.z * 100 + 0.5) .. "%  ·  K J zoom · h j k l move · 0 whole · w width · Esc back"
end
local function pv_zoom_to(z)
    z = math.clamp(z, 1, 6)
    local first = PV.z < 1.01 and z >= 1.01
    PV.px, PV.py = PV.px * z / PV.z, PV.py * z / PV.z
    PV.z = z
    if first and PV.doc then PV.py = math.huge end
    pv_view()
end
local function pv_reset()
    PV.z, PV.px, PV.py = 1, 0, 0
    fact.fnd_view = false
    pv_view()
end
-- A picture in the preview. Its shape known (a thumbnail's), it shows at once; else
-- libvips reads its header (a few ms, the pixels are not decoded).
local function pv_show(gen, path, w, h, meta, doc)
    if gen ~= pv_gen then return end
    fit_pic(w, h)
    PV.doc = doc or false
    pv_reset()
    text.pv_img_path = path .. "?" .. gen
    if meta then text.pv_meta = meta end
    fact.pv_kind = 2
end
local function pv_picture(gen, path, meta, own_size, doc, ar)
    if ar and ar > 0 and not own_size then
        pv_show(gen, path, ar * 1000, 1000, meta, doc)
        return
    end
    run("vipsheader", { "-f", "width", path }, function(wo)
        run("vipsheader", { "-f", "height", path }, function(ho)
            if gen ~= pv_gen then return end
            local w, h = tonumber(string.match(wo or "", "%d+")), tonumber(string.match(ho or "", "%d+"))
            if not (w and h) and ar and ar > 0 then w, h = ar * 1000, 1000 end
            pv_show(gen, path, w, h, meta and (meta .. ((own_size and w) and (" · " .. math.floor(w) .. " × " .. math.floor(h)) or "")), doc)
        end)
    end)
end
-- Pages and frames drawn for the preview, kept by file and time: a second look is instant.
local pv_cache = {}
run("find", { folder .. "/finder-cache", "-maxdepth", "1", "-name", "pv-*.png", "-printf", "%f\n" }, function(out)
    for l in string.gmatch(out or "", "[^\n]+") do pv_cache[l] = true end
end)
local function xml_text(x)
    x = string.gsub(x, "</w:p>", "\n")
    x = string.gsub(x, "</text:p>", "\n"); x = string.gsub(x, "</text:h>", "\n")
    x = string.gsub(x, "</a:p>", "\n"); x = string.gsub(x, "</si>", "\n")
    x = string.gsub(x, "<w:tab/>", "    "); x = string.gsub(x, "<text:tab/>", "    ")
    x = string.gsub(x, "<[^>]+>", "")
    x = string.gsub(x, "&lt;", "<"); x = string.gsub(x, "&gt;", ">"); x = string.gsub(x, "&quot;", '"'); x = string.gsub(x, "&apos;", "'"); x = string.gsub(x, "&amp;", "&")
    x = string.gsub(x, "\n%s*\n%s*\n+", "\n\n")
    return (string.gsub(x, "^%s+", ""))
end
local function page_trim(png, done)
    run("magick", { png, "-fuzz", "10%", "-trim", "+repage", "-bordercolor", "white", "-border", "3%", png }, function() done() end)
end
local CACHE = folder .. "/finder-cache"
run("mkdir", { "-p", CACHE }, nil, { output = false })
local render_busy, render_next = false, nil
local function render_office(job)
    if render_busy then render_next = job; return end
    render_busy = true
    local function done()
        render_busy = false
        local n = render_next; render_next = nil
        if n then render_office(n) end
    end
    local key = string.gsub(job.path, "[^%w]", "_") .. "-" .. job.t .. "-page"
    local png = CACHE .. "/" .. key
    run("stat", { png .. ".png" }, function(_, have)
        if have == 0 then job.ready(png .. ".png"); done(); return end
        local jobdir = CACHE .. "/job"
        run("soffice", { "--headless", "-env:UserInstallation=file://" .. folder .. "/lo-profile", "--convert-to", "pdf", "--outdir", jobdir, job.path }, function(_, code)
            local stem = string.match(job.path, "([^/]+)%.[^%.]+$") or "out"
            if code ~= 0 then done(); return end
            run("pdftoppm", { "-png", "-f", "1", "-l", "1", "-singlefile", "-scale-to", "2400", jobdir .. "/" .. stem .. ".pdf", png }, function(_, c2)
                if c2 ~= 0 then done(); return end
                page_trim(png .. ".png", function() job.ready(png .. ".png"); done() end)
            end)
        end)
    end)
end
local function prose(gen, txt, meta)
    if gen ~= pv_gen then return end
    text.pv_text = string.sub(txt, 1, 3000)
    if meta then text.pv_meta = meta end
    fact.pv_kind = 6
end
local function dur(sec)
    sec = math.floor((tonumber(sec) or 0) + 0.5)
    if sec >= 3600 then return string.format("%d:%02d:%02d", sec // 3600, sec % 3600 // 60, sec % 60) end
    return string.format("%d:%02d", sec // 60, sec % 60)
end
local help_on = false
-- A video in the preview plays in place (K, or a click): the engine's `video` service
-- decodes it at the size it is drawn, with its sound; it stops when the cursor moves on.
local function video_stop()
    if fact.fnd_vplay then pcall(sys.call, "video.stop") end
    fact.fnd_vplay = false
    S.pv_video_on = nil
end
local function video_toggle()
    local p = S.pv_video
    if not p then return false end
    if S.pv_video_on == p then pcall(sys.call, "video.toggle"); return true end
    pcall(sys.call, "video.play", p, 1248, 800)
    S.pv_video_on = p
    fact.fnd_vplay = true
    return true
end
S.video_stop = video_stop
preview = function(e)
    if help_on then return end
    if S.pv_video_on and (not e or e.path ~= S.pv_video_on) then video_stop() end
    if not e or e.path ~= S.pv_video then S.pv_video = nil; fact.fnd_isvid = false end
    pv_gen += 1
    local gen = pv_gen
    pv_reset()
    if not e or e.head then text.pv_name = ""; text.pv_meta = ""; fact.pv_kind = 0; return end
    if not fact.fnd_pv_on then return end
    text.pv_name = e.name
    text.pv_meta = e.app and "Application" or tilde(e.parent)
    if e.app then fact.pv_kind = 4; return end
    -- Its thumbnail at once, when there is one: the sharp picture replaces it when ready.
    local thumbp, thumbar = nil, 0
    if not e.dir and e.mtime then
        thumbp, thumbar = picture_of(e, false)
        if thumbp then pv_show(gen, thumbp, thumbar * 1000, 1000, nil, false) end
    end
    if e.size and e.mtime then text.pv_meta = human(e.size) .. " · " .. (when(e.mtime) == "now" and "just now" or when(e.mtime)) end
    -- One step: at once. Held (a key repeating): a moment's pause, so not every row passed starts one.
    local held = S.pv_recent
    S.pv_recent = (S.pv_recent or 0) + 1
    after(150, function() S.pv_recent = (S.pv_recent or 1) - 1; if S.pv_recent <= 0 then S.pv_recent = nil end end)
    after(held and 80 or 0, function()
        if gen ~= pv_gen then return end
        if e.dir then
            run("find", { e.path, "-mindepth", "1", "-maxdepth", "1", "-printf", "%y%Y\t%s\t%T@\t%f\n" }, function(out)
                if gen ~= pv_gen then return end
                local ds, fs, stat = {}, {}, {}
                for l in string.gmatch(out or "", "[^\n]+") do
                    local _, ty, size, t, name = string.match(l, "^(%a)(%a)\t(%d+)\t([%d%.]+)\t(.+)$")
                    if name and (S.hidden or string.sub(name, 1, 1) ~= ".") then
                        if ty == "d" then ds[#ds + 1] = name else fs[#fs + 1] = name; stat[name] = { tonumber(size), tonumber(t) } end
                    end
                end
                table.sort(ds, function(a, b) return natural_less(string.lower(a), string.lower(b)) end)
                table.sort(fs, function(a, b) return natural_less(string.lower(a), string.lower(b)) end)
                -- What you usually open in it comes first (Hover Menus, Fitchett et al. CHI 2013).
                local tiles, seen = {}, {}
                for k, c in ipairs(ar_toward(e.path)) do
                    if k <= 3 then
                        local nm = base_of(c.path)
                        local isdir = table.find(ds, nm) ~= nil
                        tiles[#tiles + 1] = { name = nm, dir = isdir, hint = true }
                        seen[nm] = true
                    end
                end
                for _, x in ipairs(ds) do if not seen[x] then tiles[#tiles + 1] = { name = x, dir = true } end end
                for _, x in ipairs(fs) do if not seen[x] then tiles[#tiles + 1] = { name = x, dir = false } end end
                local total = #ds + #fs
                local cap = 24
                local room = (#tiles > cap and not fact.pvd_list) and cap - 1 or cap
                -- Its files' thumbnails: those made already at once, the rest asked for (in the
                -- background, after the folder's own) and filled in as they come.
                local function fill()
                    if gen ~= pv_gen then S.pvd_fill = nil; return end
                    local grid = {}
                    for k = 1, math.min(room, #tiles) do
                        local t = tiles[k]
                        local tp = join(e.path, t.name)
                        local pic = nil
                        local st = stat[t.name]
                        if not t.dir and st and THUMBABLE[ext_of(t.name)] then
                            pic = (picture_of(entry(tp, false, st[1], st[2]), false))
                        end
                        grid[k] = { name = t.name, dir = t.dir, ic = pic or ficon.of(t.name, t.dir, tp), hint = t.hint == true, sub = (st and not t.dir) and human(st[1]) or "" }
                    end
                    model.pvd = grid
                end
                fill()
                thumb_pump()
                S.pvd_fill = fill
                fact.pvd_more = math.max(0, #tiles - room)
                text.pv_meta = total .. (total == 1 and " item · " or " items · ") .. tilde(e.parent)
                text.pv_text = total == 0 and "Empty folder" or ""
                fact.pv_kind = 7
            end)
            return
        end
        local function known(then_)
            if e.size and e.mtime then then_(tostring(e.size) .. " " .. tostring(math.floor(e.mtime))) return end
            run("stat", { "-L", "-c", "%s %Y", e.path }, function(out) then_(out) end)
        end
        known(function(out)
            if gen ~= pv_gen then return end
            local size, t = string.match(out or "", "(%d+) (%d+)")
            local meta = human(size) .. " · " .. (when(t) == "now" and "just now" or when(t))
            text.pv_meta = meta
            local x = ext_of(e.path)
            local k = kind_of(e)
            if k == "image" and not (x == "psd" or x == "xcf" or x == "kra" or EXT.image[x] and string.find("cr2 cr3 nef arw dng orf rw2 raf", x, 1, true)) then
                -- The file itself (the engine decodes it in the background, at the size it is drawn).
                pv_picture(gen, e.path, meta, true, false, thumbar)
            elseif k == "pdf" or k == "video" or (k == "image") then
                -- Drawn once at the size it shows (1400 px across), kept by file and time.
                local name = "pv-" .. thumb_key(e) .. ".png"
                local out_png = folder .. "/finder-cache/" .. name
                local info = nil
                local function done_video(path)
                    local w, h = string.match(info or "", "(%d+),(%d+)")
                    local d = string.match(info or "", "\n%s*([%d%.]+)") or string.match(info or "", "^([%d%.]+)")
                    pv_picture(gen, path, "Video · " .. (d and (dur(d) .. " · ") or "") .. (w and (w .. "×" .. h .. " · ") or "") .. meta .. " · K plays", false, false, (w and tonumber(h) and tonumber(h) > 0) and (tonumber(w) / tonumber(h)) or thumbar)
                    S.pv_video = e.path
                    fact.fnd_isvid = true
                end
                local function ready(path)
                    if gen ~= pv_gen then return end
                    if k == "pdf" then pv_picture(gen, path, "PDF · " .. meta, false, true)
                    elseif k == "image" then pv_picture(gen, path, meta, true)
                    elseif info then done_video(path)
                    else S.pv_frame = path end
                end
                if k == "video" then
                    -- (its length and size asked at the same time as its frame, not after)
                    run("ffprobe", { "-v", "error", "-select_streams", "v:0", "-show_entries", "stream=width,height:format=duration", "-of", "csv=p=0", e.path }, function(o)
                        info = o or ""
                        if gen == pv_gen and S.pv_frame then local f = S.pv_frame; S.pv_frame = nil; done_video(f) end
                    end)
                    S.pv_frame = nil
                end
                if pv_cache[name] then ready(out_png) else
                    local cmd, args
                    if k == "pdf" then cmd, args = "pdftoppm", { "-png", "-f", "1", "-l", "1", "-singlefile", "-scale-to", "1400", e.path, string.sub(out_png, 1, -5) }
                    elseif k == "image" then cmd, args = "magick", { e.path .. "[0]", "-flatten", "-resize", "1400x1400>", out_png }
                    else cmd, args = "ffmpeg", { "-y", "-loglevel", "error", "-ss", "1", "-i", e.path, "-frames:v", "1", "-vf", "scale=1248:-2", out_png } end
                    run(cmd, args, function(_, code)
                        if code ~= 0 then if gen == pv_gen and not thumbp then fact.pv_kind = 4 end return end
                        local function keep() pv_cache[name] = true; ready(out_png) end
                        if k == "pdf" then page_trim(out_png, keep) else keep() end
                    end)
                end
            elseif EXT.office[x] then
                local kind_name = EXT.slides[x] and "Presentation" or EXT.sheet[x] and "Spreadsheet" or "Document"
                text.pv_meta = kind_name .. " · " .. meta
                if OFFICE_XML[x] then
                    run("unzip", { "-p", e.path, OFFICE_XML[x] }, function(xml)
                        if gen ~= pv_gen or fact.pv_kind == 2 then return end
                        local words = xml_text(xml or "")
                        prose(gen, words ~= "" and words or "(no text)")
                    end)
                else
                    prose(gen, "Rendering a preview…")
                end
                render_office({ path = e.path, t = t or "0", ready = function(png)
                    if gen == pv_gen then pv_picture(gen, png, kind_name .. " · " .. meta, nil, true) end
                end })
            elseif EXT.archive[x] or x == "epub" then
                -- What is inside, as a folder's preview: its folders first (how much each holds),
                -- then its files (their size), by type; one folder at its top is stepped into.
                run("bsdtar", { "-tvf", e.path }, function(out2, code)
                    if gen ~= pv_gen then return end
                    if code ~= 0 then fact.pv_kind = 4; return end
                    local files, unpacked = {}, 0
                    for l in string.gmatch(out2 or "", "[^\n]+") do
                        local kind, size, p = string.match(l, "^(%S)%S*%s+%S+%s+%S+%s+%S+%s+(%d+)%s+%a+%s+%d+%s+%S+%s+(.+)$")
                        if p then
                            p = string.gsub(p, "/$", "")
                            if kind ~= "d" then files[#files + 1] = { p = p, size = tonumber(size) or 0 }; unpacked += tonumber(size) or 0 end
                        end
                    end
                    -- One folder holding everything: show what is in it.
                    local prefix = ""
                    while true do
                        local top, all_under = nil, #files > 0
                        for _, f in ipairs(files) do
                            local first = string.match(string.sub(f.p, #prefix + 1), "^([^/]+)/")
                            if not first or (top and first ~= top) then all_under = false; break end
                            top = first
                        end
                        if not (all_under and top) then break end
                        prefix = prefix .. top .. "/"
                    end
                    local folders, order, loose = {}, {}, {}
                    for _, f in ipairs(files) do
                        local rest = string.sub(f.p, #prefix + 1)
                        local first, more = string.match(rest, "^([^/]+)/(.+)$")
                        if first then
                            if not folders[first] then folders[first] = { n = 0, size = 0 }; order[#order + 1] = first end
                            folders[first].n += 1
                            folders[first].size += f.size
                        elseif rest ~= "" then
                            loose[#loose + 1] = { name = rest, size = f.size }
                        end
                    end
                    table.sort(order, function(a, b) return natural_less(string.lower(a), string.lower(b)) end)
                    table.sort(loose, function(a, b) return natural_less(string.lower(a.name), string.lower(b.name)) end)
                    local rows = {}
                    for _, name in ipairs(order) do
                        local d = folders[name]
                        rows[#rows + 1] = { name = name, dir = true, ic = ficon.of(name, true, name), hint = false, sub = n_items(d.n) .. " · " .. human(d.size) }
                    end
                    for _, f in ipairs(loose) do
                        rows[#rows + 1] = { name = f.name, dir = false, ic = ficon.of(f.name, false, f.name), hint = false, sub = human(f.size) }
                    end
                    local room = 24
                    local shown = {}
                    for i = 1, math.min(room, #rows) do shown[i] = rows[i] end
                    model.pvd = shown
                    fact.pvd_more = math.max(0, #rows - room)
                    S.pvd_fill = nil
                    text.pv_meta = (x == "epub" and "E-book" or "Archive") .. " · " .. n_items(#files) .. " · " .. human(unpacked) .. " unpacked · " .. meta
                        .. (prefix ~= "" and (" · in " .. string.gsub(prefix, "/$", "")) or "")
                    text.pv_text = #files == 0 and "Empty archive" or ""
                    fact.pv_kind = 8
                end)
            elseif k == "audio" then
                run("ffprobe", { "-v", "error", "-show_entries", "format=duration:format_tags=title,artist,album", "-of", "default=nw=1", e.path }, function(out2)
                    if gen ~= pv_gen then return end
                    local tag = function(k2) return string.match(out2 or "", "TAG:" .. k2 .. "=([^\n]+)") end
                    local title, artist, album = tag("title") or e.name, tag("artist"), tag("album")
                    local length = dur(string.match(out2 or "", "duration=([%d%.]+)"))
                    local line = (artist and (artist .. " — ") or "") .. title .. " · " .. length
                    pv_slot = 1 - pv_slot
                    local cover = folder .. "/finder-pv" .. pv_slot .. ".png"
                    run("ffmpeg", { "-y", "-loglevel", "error", "-i", e.path, "-an", "-frames:v", "1", cover }, function(_, code)
                        if gen ~= pv_gen then return end
                        if code == 0 then pv_picture(gen, cover, line)
                        else prose(gen, title .. "\n" .. (artist or "") .. "\n" .. (album or "") .. "\n\n" .. length, "Audio · " .. meta) end
                    end)
                end)
            elseif k == "font" then
                pv_slot = 1 - pv_slot
                local sheet = folder .. "/finder-pv" .. pv_slot .. ".png"
                run("magick", { "-size", "928x620", "xc:#1b1925", "-font", e.path, "-fill", "#f6f8fc",
                    "-pointsize", "120", "-annotate", "+44+160", "Aa Gg",
                    "-pointsize", "52", "-annotate", "+44+270", "The quick brown fox",
                    "-annotate", "+44+340", "jumps over the lazy dog",
                    "-pointsize", "40", "-annotate", "+44+440", "0123456789 !?&@#%",
                    "-pointsize", "28", "-annotate", "+44+520", "ABCDEFGHIJKLMNOPQRSTUVWXYZ", sheet }, function(_, code)
                    if gen ~= pv_gen then return end
                    if code == 0 then pv_picture(gen, sheet, "Font · " .. meta) else fact.pv_kind = 4 end
                end)
            elseif k == "text" or (k == "other" and (tonumber(size) or 0) < 2000000) then
                run("head", { "-c", "6000", e.path }, function(txt)
                    if gen ~= pv_gen then return end
                    txt = txt or ""
                    if string.find(txt, "\0", 1, true) then
                        run("file", { "-b", e.path }, function(desc)
                            if gen ~= pv_gen then return end
                            desc = string.gsub(desc or "", "%s+$", "")
                            if #desc > 60 then desc = string.sub(desc, 1, 60) .. "…" end
                            text.pv_meta = (desc ~= "" and (desc .. " · ") or "") .. meta
                            fact.pv_kind = 4
                        end)
                        return
                    end
                    local lines, n = {}, 0
                    for l in string.gmatch(txt, "([^\n]*)\n?") do
                        n += 1
                        if n > 40 then break end
                        l = string.gsub(l, "\t", "    ")
                        if utf8.len(l) and utf8.len(l) > 110 then l = string.sub(l, 1, utf8.offset(l, 110) - 1) .. "…" end
                        lines[#lines + 1] = l
                    end
                    text.pv_text = table.concat(lines, "\n")
                    fact.pv_kind = 1
                end)
            else
                run("file", { "-b", e.path }, function(desc)
                    if gen ~= pv_gen then return end
                    desc = string.gsub(desc or "", "%s+$", "")
                    if #desc > 60 then desc = string.sub(desc, 1, 60) .. "…" end
                    text.pv_meta = (desc ~= "" and (desc .. " · ") or "") .. meta
                    fact.pv_kind = 4
                end)
            end
        end)
    end)
end

-- ── the search (i) ───────────────────────────────────────────────────
-- Words match names first, then paths, then letters in order; every word has
-- to match. Ranked by how well, by AccessRank from where you are, by what
-- these first letters led to before (it learns from what you choose), by
-- zoxide, and by being near the top of ~ rather than deep in a tree.
-- Understood too:
--   kinds   pdf · image(s)/photo(s)/picture(s) · video(s) · audio/song(s)/music ·
--           doc(s) · sheet(s) · slide(s) · code · archive(s)/zip · font(s) ·
--           folder(s)/dir(s) · book(s) · screenshot(s)       (with other words, or `kind:`)
--   .ext / ext:pdf     the extension
--   today · yesterday · week · month · year · recent · 3d · 2w · 6m    modified since
--   >10mb  <500k  big   its size (fd, live)
--   ~/… or /…   a path: what is in that folder, the last part filtered (Tab completes)
--   "words"     only what has them inside (text, code, PDFs, Office files, e-books: rga)
-- Three letters or more also look inside files after a pause, as a section of
-- their own under the names ("Inside files").
local KIND_WORDS = {
    pdf = "pdf", pdfs = "pdf", image = "image", images = "image", photo = "image", photos = "image", picture = "image", pictures = "image",
    pic = "image", pics = "image", img = "image", video = "video", videos = "video", movie = "video", movies = "video", clip = "video",
    audio = "audio", song = "audio", songs = "audio", music = "audio", doc = "office", docs = "office", document = "office",
    documents = "office", word = "office", sheet = "sheet", sheets = "sheet", spreadsheet = "sheet", spreadsheets = "sheet", excel = "sheet",
    slide = "slides", slides = "slides", presentation = "slides", deck = "slides", code = "text", archive = "archive", archives = "archive",
    zip = "archive", font = "font", fonts = "font", folder = "folder", folders = "folder", dir = "folder", dirs = "folder",
    book = "book", books = "book", ebook = "book", screenshot = "screenshot", screenshots = "screenshot",
}
local DATE_WORDS = { today = 1, yesterday = 2, week = 7, month = 31, year = 366, recent = 14, recently = 14, new = 7, latest = 7 }
local function parse_query(raw)
    local Q = { words = {}, kinds = {}, exts = {}, days = nil, size = nil, content = nil, path = nil }
    local s = raw
    -- "quoted": inside files.
    s = string.gsub(s, '"([^"]*)"?', function(inner) Q.content = inner; return " " end)
    local first = string.match(s, "^%s*(%S+)")
    if first and (string.sub(first, 1, 1) == "/" or string.sub(first, 1, 1) == "~") then Q.path = first end
    local tokens = {}
    for t in string.gmatch(s, "%S+") do tokens[#tokens + 1] = t end
    local plain = 0
    for _, t in ipairs(tokens) do
        local lt = string.lower(t)
        if not (KIND_WORDS[lt] or DATE_WORDS[lt] or string.match(lt, "^%.%w+$") or string.match(lt, "^[<>]")) then plain += 1 end
    end
    for i, t in ipairs(tokens) do
        local lt = string.lower(t)
        if Q.path and i == 1 then
            -- (the path itself)
        elseif string.match(lt, "^ext:(%w+)$") then Q.exts[string.match(lt, "^ext:(%w+)$")] = true
        elseif string.match(lt, "^kind:(%w+)$") and KIND_WORDS[string.match(lt, "^kind:(%w+)$")] then Q.kinds[KIND_WORDS[string.match(lt, "^kind:(%w+)$")]] = true
        elseif string.match(lt, "^%.%w+$") and #lt <= 6 then Q.exts[string.sub(lt, 2)] = true
        elseif string.match(lt, "^[<>]%d+[kmgt]?b?$") then
            local op, n, u = string.match(lt, "^([<>])(%d+)([kmgt]?)")
            Q.size = (op == ">" and "+" or "-") .. n .. (u == "" and "k" or u)
        elseif lt == "big" or lt == "large" or lt == "huge" then Q.size = "+100m"
        elseif string.match(lt, "^%d+[dwmy]$") then
            local n, u = string.match(lt, "^(%d+)([dwmy])$")
            Q.days = tonumber(n) * ({ d = 1, w = 7, m = 31, y = 366 })[u]
        elseif DATE_WORDS[lt] and (plain > 0 or #tokens > 1) then Q.days = DATE_WORDS[lt]
        elseif (lt == "last" or lt == "this" or lt == "from" or lt == "in" or lt == "of") and #tokens > 1 then
            -- (glue words: "pdfs from last week")
        elseif KIND_WORDS[lt] and (plain > 0 or #tokens > 1) then Q.kinds[KIND_WORDS[lt]] = true
        else
            for w in string.gmatch(norm(lt), "%S+") do Q.words[#Q.words + 1] = w end
        end
    end
    return Q
end
local function kind_ok(Q, e)
    if next(Q.exts) and not Q.exts[ext_of(e.path)] then return false end
    if next(Q.kinds) then
        local k = kind_of(e)
        local x = ext_of(e.path)
        local ok = Q.kinds[k] or (Q.kinds.sheet and EXT.sheet[x]) or (Q.kinds.slides and EXT.slides[x]) or (Q.kinds.office and x == "pdf")
            or (Q.kinds.screenshot and k == "image" and string.find(e.low_name, "screenshot", 1, true))
            or (Q.kinds.book and EXT.book[x])
        if not ok then return false end
    end
    return true
end
local function qkey(raw) return string.sub(norm(string.lower(raw)), 1, 8) end
local function learn_choice(raw, path)
    local k = qkey(raw)
    if k == "" then return end
    for n = 1, #k do
        local p = string.sub(k, 1, n)
        store.qmap[p] = store.qmap[p] or {}
        store.qmap[p][path] = (store.qmap[p][path] or 0) + 1
    end
    save()
end
local function personal(e, raw)
    local s = ar_score(e.path, S.cwd) * 14
    local z = zox[e.path]
    if z then s += math.min(30, z / 4) end
    local qm = store.qmap[qkey(raw)]
    if qm and qm[e.path] then
        local tot = 0
        for _, n in pairs(qm) do tot += n end
        s += 90 * qm[e.path] / tot
    end
    -- Near ~ beats deep in a tree; inside where you are beats elsewhere.
    local depth = 0
    for _ in string.gmatch(tilde(e.path), "/") do depth += 1 end
    s -= depth * 2
    if string.sub(e.path, 1, #S.cwd + 1) == S.cwd .. "/" then s += 12 end
    if string.find(e.path, "/%.", 1) then s -= 10 end
    return s
end
local jump_gen = 0
local content_id = nil
local function set_results(list)
    S.view = list
    S.sel = math.clamp(S.sel, 0, math.max(0, #list - 1))
    show()
end
local function search(raw)
    jump_gen += 1
    local gen = jump_gen
    if content_id then kill(content_id); content_id = nil end
    S.content_busy = false
    local Q = parse_query(raw)
    S.sel, S.off = 0, 0
    -- A path: what is in that folder, filtered by what follows its last slash.
    if Q.path then
        local p = untilde(Q.path)
        local dir, part = string.match(p, "^(.*)/([^/]*)$")
        if dir == "" then dir = "/" end
        dir = dir or p
        run("find", { dir, "-mindepth", "1", "-maxdepth", "1", "-printf", "%y%Y\t%s\t%T@\t%f\n" }, function(out)
            if gen ~= jump_gen then return end
            local list = {}
            local lp = string.lower(part or "")
            for l in string.gmatch(out or "", "[^\n]+") do
                local y, ty, size, t, name = string.match(l, "^(%a)(%a)\t(%d+)\t([%d%.]+)\t(.+)$")
                if name and (lp ~= "" and string.sub(string.lower(name), 1, #lp) == lp or lp == "" and string.sub(name, 1, 1) ~= ".") then
                    list[#list + 1] = entry(join(dir, name), ty == "d", tonumber(size), tonumber(t), y == "l")
                end
            end
            sort_entries(list)
            set_results(list)
        end)
        return
    end
    -- Nothing typed yet: what AccessRank expects you to want from here.
    if #Q.words == 0 and not Q.days and not Q.size and not next(Q.kinds) and not next(Q.exts) and not Q.content then
        local cands = {}
        for p, it in pairs(AR.items) do
            if p ~= S.cwd then cands[#cands + 1] = { path = p, s = ar_score(p, S.cwd) } end
        end
        stable_rank(cands, S.jump_prev)
        S.jump_prev = {}
        local list = {}
        for _, c in ipairs(cands) do
            if #list >= 60 then break end
            local e = entry(c.path, is_dir(c.path))
            list[#list + 1] = e
            S.jump_prev[#list] = c.path
        end
        set_results(list)
        return
    end
    -- Dates and sizes: fd knows them (~70 ms for all of ~); names are ranked here after.
    local function rank(pool)
        local scored = {}
        for _, e in ipairs(pool) do
            if kind_ok(Q, e) then
                local f = #Q.words == 0 and 0 or fuzzy(e, Q.words)
                if f then scored[#scored + 1] = { e = e, s = f + personal(e, raw) } end
            end
        end
        table.sort(scored, function(a, b) return a.s > b.s end)
        local list = {}
        for i = 1, math.min(#scored, 300) do list[i] = scored[i].e end
        return list
    end
    local function inside(names)
        -- Looking inside files: rga (text, code, PDFs, Office files, e-books, archives), after a pause.
        local phrase = Q.content or (#Q.words > 0 and table.concat(Q.words, " ") or nil)
        if not phrase or #phrase < 3 then return end
        after(Q.content and 0 or 320, function()
            if gen ~= jump_gen then return end
            S.content_busy = true
            text.fnd_status = status_line()
            local roots = { HOME .. "/Documents", HOME .. "/Downloads", HOME .. "/Desktop" }
            if S.cwd ~= HOME and S.cwd ~= "/" then table.insert(roots, 1, S.cwd) end
            local args = { "-i", "-F", "--max-count", "1", "--max-columns", "160", "--max-columns-preview", "--no-heading", "--with-filename", "--color", "never", "--max-filesize", "60M", "--", phrase }
            for _, r in ipairs(roots) do args[#args + 1] = r end
            local found, seen = {}, {}
            for _, e in ipairs(names) do seen[e.path] = true end
            content_id = spawn("rga", args, function(line)
                if gen ~= jump_gen or #found >= 40 then return end
                local path, rest = string.match(line, "^(/.-):(.*)$")
                if path and not seen[path] then
                    seen[path] = true
                    local e = entry(path, false)
                    e.snippet = string.gsub(string.gsub(rest, "^%s*Page %d+:%s*", ""), "%s+", " ")
                    if kind_ok(Q, e) then found[#found + 1] = e end
                end
            end, function()
                content_id = nil
                if gen ~= jump_gen then return end
                S.content_busy = false
                if #found > 0 then
                    for _, e in ipairs(found) do e.personal = personal(e, raw) end
                    table.sort(found, function(a, b) return a.personal > b.personal end)
                    local list = {}
                    if not Q.content then for _, e in ipairs(names) do list[#list + 1] = e end end
                    list[#list + 1] = { name = "Inside files", head = true, path = "", dir = false, parent = "" }
                    for _, e in ipairs(found) do list[#list + 1] = e end
                    local keep = S.view[S.sel + 1]
                    S.view = list
                    if keep then for i, e in ipairs(list) do if e == keep then S.sel = i - 1 end end end
                end
                show()
            end)
        end)
    end
    if Q.days or Q.size then
        local args = { "--color", "never", "-a", "-E", "node_modules", "-E", ".cache", "-E", "target", "-E", ".git" }
        if Q.days then args[#args + 1] = "--changed-within"; args[#args + 1] = Q.days .. "d" end
        if Q.size then args[#args + 1] = "--size"; args[#args + 1] = Q.size; args[#args + 1] = "-t"; args[#args + 1] = "f" end
        for x in pairs(Q.exts) do args[#args + 1] = "-e"; args[#args + 1] = x end
        args[#args + 1] = "."
        args[#args + 1] = HOME
        run("fd", args, function(out)
            if gen ~= jump_gen then return end
            local pool = {}
            for l in string.gmatch(out or "", "[^\n]+") do
                local p = string.gsub(l, "/$", "")
                pool[#pool + 1] = entry(p, string.sub(l, -1) == "/")
            end
            local list = rank(pool)
            -- Newest first among equals: a date was asked for.
            set_results(list)
            inside(list)
        end)
        return
    end
    if Q.content or #Q.words == 0 then
        -- Only inside files (a "quoted" search), or only a kind (no words): fd lists that kind.
        if Q.content then set_results({}); inside({}); return end
        local args = { "--color", "never", "-a", "-t", "f", "-E", "node_modules", "-E", ".cache", "-E", "target", "-E", ".git", "-E", "go/pkg" }
        local exts = {}
        for x in pairs(Q.exts) do exts[x] = true end
        for k in pairs(Q.kinds) do
            local set = (k == "pdf" and { pdf = true }) or EXT[k] or (k == "screenshot" and EXT.image) or {}
            for x in pairs(set) do exts[x] = true end
        end
        for x in pairs(exts) do args[#args + 1] = "-e"; args[#args + 1] = x end
        args[#args + 1] = "."
        args[#args + 1] = HOME
        run("fd", args, function(out)
            if gen ~= jump_gen then return end
            local pool = {}
            for l in string.gmatch(out or "", "[^\n]+") do pool[#pool + 1] = entry(l, false) end
            set_results(rank(pool))
        end)
        return
    end
    fzf_rank(Q.words, false, 400, function(pool)
        if gen ~= jump_gen then return end
        -- fzf's order as a base, re-ranked by what is yours.
        local n = #pool
        for i, e in ipairs(pool) do e.fz = (n - i) * 0.25 end
        local scored = {}
        for _, e in ipairs(pool) do
            if kind_ok(Q, e) then
                local f = fuzzy(e, Q.words) or 0
                scored[#scored + 1] = { e = e, s = f + e.fz + personal(e, raw) }
            end
        end
        table.sort(scored, function(a, b) return a.s > b.s end)
        local list = {}
        for i = 1, math.min(#scored, 300) do list[i] = scored[i].e end
        set_results(list)
        inside(list)
    end)
end

-- ── opening ──────────────────────────────────────────────────────────
local function to_terminal() run(SCRIPTS .. "wm.sh", { "focus-class", "com.mitchellh.ghostty" }, nil, { output = false }) end
local function tmux_window(dir, cmd)
    local args = { "new-window", "-c", dir }
    for _, a in ipairs(cmd or {}) do args[#args + 1] = a end
    run("tmux", args, function(_, code)
        if code == 0 then to_terminal() else toast("No tmux session is running") end
    end)
end
-- Something opened from the card: it goes (the window stays, as a file manager's does).
local function done()
    if fact.fnd_win and not (fact.app == "fnd" or (fact.expanded and fact.panel == "fnds")) then return end
    if fact.app == "fnd" then fact.app = "none" else fact.expanded = false end
end
local function launch(e)
    ar_visit(e.path, e.dir == true)
    if string.sub(S.cwd, 1, 1) == "/" then
        AR.tr[S.cwd] = AR.tr[S.cwd] or {}
    end
    done()
    if EXT.text[ext_of(e.path)] then
        tmux_window(e.parent, { "nvim", e.path })
    else
        run("xdg-open", { e.path }, nil, { output = false })
    end
end
local function enter(e)
    if not e or e.head then return end
    if S.mode == "dest" then
        fact.fnd_insert = false
        focus()
        S.mode = "dir"
        apply_filter()
        S.drop_carry(e.path)
        show()
        return
    end
    if S.mode == "jump" then learn_choice(text.fq or "", e.path) end
    if e.app then
        local target = S.with_target
        S.mode = "dir"
        run("gtk-launch", { e.app, target }, nil, { output = false })
        ar_visit(target)
        done()
        show()
        return
    end
    if e.dir then
        fact.fnd_insert = false
        focus()
        go(e.path)
    elseif S.mode == "jump" then
        -- A file found: shown where it lives (Enter again opens it), as Finder's "Show in Enclosing Folder";
        -- l / Enter on it straight from the results opens it.
        fact.fnd_insert = false
        focus()
        launch(e)
    else
        launch(e)
    end
end
local function reveal(e)
    if not e or e.head or not e.parent then return end
    fact.fnd_insert = false
    focus()
    go(e.dir and e.path or e.parent, (not e.dir) and e.path or nil)
end

-- ── the file operations, each undoable (u) ───────────────────────────
local function chosen()
    local list = {}
    for pth in pairs(S.marked) do list[#list + 1] = pth end
    table.sort(list)
    if #list == 0 then
        local e = S.view[S.sel + 1]
        if e and not e.head and not e.app then list[1] = e.path end
    end
    return list
end
local function unmark() S.marked, S.nmarks, S.visual = {}, 0, nil end
local function after_change(name_or_path)
    unmark()
    local keep = name_or_path
    if keep and not string.find(keep, "/", 1, true) then keep = join(S.cwd, keep) end
    S.reload(keep)
    after(2000, function() index() end)
end
local function unique_in(dest, name, taken)
    if not taken[name] then return name end
    local stem, ext = string.match(name, "^(.+)(%.[^%.]+)$")
    if not stem then stem, ext = name, "" end
    local k = 1
    local out
    repeat
        out = stem .. (k == 1 and " (copy)" or (" (copy " .. k .. ")")) .. ext
        k += 1
    until not taken[out]
    return out
end
local function uri_list(paths)
    local t = {}
    for _, p in ipairs(paths) do
        t[#t + 1] = "file://" .. string.gsub(p, "[^%w/%._~%-]", function(c) return string.format("%%%02X", string.byte(c)) end)
    end
    return table.concat(t, "\r\n")
end
local function from_uris(data)
    local list = {}
    for l in string.gmatch(data or "", "[^\r\n]+") do
        local p = string.match(l, "^file://(.+)$")
        if p then
            p = string.gsub(p, "%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end)
            list[#list + 1] = p
        elseif string.sub(l, 1, 1) == "/" then list[#list + 1] = l end
    end
    return list
end
-- ── carrying (moving and copying, as a drag made of keys) ────────────
-- yy (copy) or dd (move) PICKS UP what is marked, or the one under the cursor:
-- it is carried, shown at the foot as a small stack of what it is. Then you go
-- anywhere, by every way there is (j k l h, 1–9, ' marks, g places, i search,
-- H L): wherever the cursor rests is where it would land, lit as a drop target
-- is under a drag. A folder under the cursor: p drops it INTO that folder.
-- A file under the cursor: p drops it here. P always drops here. Esc puts it
-- down where it was. And > (move) / + (copy) "put in…": the places it usually
-- goes from here, as a list to choose from (learned from every move and copy:
-- from this folder, and for this kind of file), so the usual tidy-up is `>⏎`.
-- The mouse is the same: a row dragged onto a folder, a place on the left or a
-- crumb moves it there (copied from another program), and held over a folder
-- for a moment, that folder opens under it (spring-loaded, as Finder's).
store.dest = store.dest or {}     -- from folder → { to → { n, c, l } }
store.destk = store.destk or {}   -- kind of file → { to → { n, c, l } }
local function dest_learn(paths, to)
    local from = parent_of(paths[1] or "") or ""
    local kind = kind_of(entry(paths[1] or "", false))
    for _, t in ipairs({ { store.dest, from }, { store.destk, kind } }) do
        local tab, key = t[1], t[2]
        tab[key] = tab[key] or {}
        local w = tab[key][to] or { n = 0, c = 0, l = AR.tick }
        w.c = crf_now(w.c, w.l) + 1
        w.l = AR.tick
        w.n += 1
        tab[key][to] = w
    end
    ar_visit(to, true)
end
local function carry_show()
    local c = S.reg
    fact.fnd_carrying = c ~= nil
    if not c then text.fnd_carry = ""; model.fcarry = {}; return end
    local stack = {}
    for i = 1, math.min(3, #c.paths) do
        local p = c.paths[i]
        local e = (S.by_path and S.by_path[p]) or entry(p, is_dir(p))
        local pic = (picture_of(e, false))
        stack[i] = { ic = pic or ficon.of(e.name, e.dir, p) }
    end
    model.fcarry = stack
    local what = #c.paths == 1 and base_of(c.paths[1]) or n_items(#c.paths)
    local e = S.view[S.sel + 1]
    local into = e and e.dir and S.mode == "dir" and not e.head
    text.fnd_carry = (c.mode == "copy" and "Copying " or "Moving ") .. what .. "   ·   p " .. (into and ("into " .. e.name) or "here") .. "   ·   P here   ·   > a usual place   ·   Esc cancel"
    fact.fnd_tgt_here = not into
end
S.carry_show = carry_show
-- Copies (or moves) `paths` into `dest`; a name already there gets " (copy)", nothing is overwritten.
local function put(paths, dest, mode, then_)
    local taken = {}
    if dest == S.cwd then for _, e in ipairs(S.entries) do taken[e.name] = true end end
    run("find", { dest, "-mindepth", "1", "-maxdepth", "1", "-printf", "%f\n" }, function(out)
        for l in string.gmatch(out or "", "[^\n]+") do taken[l] = true end
        local jobs = {}
        for _, src in ipairs(paths) do
            local same_place = parent_of(src) == dest
            if not (mode == "move" and same_place) and src ~= dest and string.sub(dest, 1, #src + 1) ~= src .. "/" then
                local out_name = unique_in(dest, base_of(src), taken)
                taken[out_name] = true
                jobs[#jobs + 1] = { src = src, dst = join(dest, out_name) }
            end
        end
        if #jobs == 0 then if then_ then then_(0, 0, nil) end return end
        fact.fnd_busy = true
        local ok_n, bad = 0, 0
        local made = {}
        local function step(i)
            local j = jobs[i]
            if not j then
                fact.fnd_busy = false
                text.fnd_busy_text = ""
                if mode == "move" then table.insert(S.undo, { kind = "move", pairs = made })
                else table.insert(S.undo, { kind = "copy", made = made }) end
                if then_ then then_(ok_n, bad, jobs[1] and base_of(jobs[1].dst)) end
                return
            end
            text.fnd_busy_text = (mode == "move" and "Moving " or "Copying ") .. i .. " of " .. #jobs .. " · " .. base_of(j.src)
            local cmd, args = "mv", { "--", j.src, j.dst }
            if mode == "copy" then cmd, args = "cp", { "-a", "--reflink=auto", "--", j.src, j.dst } end
            run(cmd, args, function(_, code)
                if code == 0 then
                    ok_n += 1
                    if mode == "move" then made[#made + 1] = { src = j.src, dst = j.dst } else made[#made + 1] = j.dst end
                else bad += 1 end
                step(i + 1)
            end)
        end
        step(1)
    end)
end
local function take(mode)
    local list = chosen()
    if #list == 0 then return end
    local set = {}
    for _, pth in ipairs(list) do set[pth] = true end
    S.reg = { mode = mode == "cut" and "cut" or "copy", paths = list, set = set, from = S.cwd }
    unmark()
    -- On the system's clipboard too, as files: another file manager, a browser's upload, a chat take them.
    run("wl-copy", { "--type", "text/uri-list" }, nil, { input = uri_list(list), output = false })
    show()
end
local drop_carry
drop_carry = function(dest)
    local c = S.reg
    if not c then return end
    local mode = c.mode == "cut" and "move" or "copy"
    put(c.paths, dest, mode, function(ok_n, bad, first)
        if ok_n > 0 then dest_learn(c.paths, dest) end
        local where = dest == S.cwd and "here" or ("into " .. base_of(dest))
        if bad == 0 then toast((mode == "copy" and "Copied " or "Moved ") .. n_items(ok_n) .. " " .. where .. " · u undoes")
        else toast((mode == "copy" and "Copied " or "Moved ") .. ok_n .. ", " .. bad .. " could not be") end
        if mode == "move" or ok_n > 0 then S.reg = nil end
        after_change(dest == S.cwd and first or nil)
    end)
end
S.drop_carry = drop_carry
-- p: into the folder under the cursor, or here (`here_only`: P).
local function paste(here_only)
    if S.reg then
        local e = S.view[S.sel + 1]
        local into = (not here_only) and e and e.dir and S.mode == "dir" and not e.head
        drop_carry(into and e.path or S.cwd)
        return
    end
    -- Nothing carried: files another program copied (Thunar, a browser…).
    run("wl-paste", { "--no-newline", "--type", "text/uri-list" }, function(out, code)
        local list = code == 0 and from_uris(out) or {}
        if #list == 0 then toast("Nothing to paste: yy picks up a copy, dd picks up to move"); return end
        S.reg = { mode = "copy", paths = list, set = {}, from = "" }
        paste(here_only)
    end)
end
-- > / +: the places it usually goes, to choose from (typing narrows them; Enter puts it there).
local function dest_pick(mode)
    if not S.reg then
        local list = chosen()
        if #list == 0 then return end
        local set = {}
        for _, p in ipairs(list) do set[p] = true end
        S.reg = { mode = mode, paths = list, set = set, from = S.cwd }
        unmark()
    elseif mode then
        S.reg.mode = mode
    end
    local c = S.reg
    local from = parent_of(c.paths[1]) or S.cwd
    local kind = kind_of(entry(c.paths[1], false))
    local scores, seen = {}, {}
    local function add(p, s)
        if p == from or c.set[p] then return end
        scores[p] = (scores[p] or 0) + s
    end
    local function learned(tab, weight)
        local total = 0
        for _, w in pairs(tab or {}) do total += w.n end
        for to, w in pairs(tab or {}) do
            add(to, weight * math.pow((w.n + 1) / (total + 1), ALPHA) * math.pow(crf_now(w.c, w.l), 1 / ALPHA))
        end
    end
    learned(store.dest[from], 100)
    learned(store.destk[kind], 40)
    for k, p in ipairs(store.pins) do if not string.find(base_of(p), "%.%w+$") then add(p, 8 - k * 0.1) end end
    for _, p in pairs(store.marks) do add(p, 6) end
    for p, it in pairs(AR.items) do
        if is_dir(p) then add(p, math.min(5, ar_score(p, from))) end
    end
    -- The folders beside it, and the one above.
    for _, e in ipairs(S.entries) do if e.dir and S.cwd == from then add(e.path, 0.5) end end
    if parent_of(from) then add(parent_of(from), 0.4) end
    local cands = {}
    for p, sc in pairs(scores) do cands[#cands + 1] = { path = p, s = sc } end
    stable_rank(cands, S.dest_prev)
    S.dest_prev = {}
    local list = {}
    for i, x in ipairs(cands) do
        if i > 120 then break end
        local e = entry(x.path, true)
        e.dir = true
        list[#list + 1] = e
        S.dest_prev[i] = x.path
    end
    S.dest_all = list
    S.mode = "dest"
    S.sel, S.off = 0, 0
    S.view = list
    text.fq = ""
    fact.fq_empty = true
    fact.fnd_qkind = 3
    fact.fnd_insert = true
    focus("fq")
    show()
end
S.dest_pick = dest_pick
local function dest_filter(raw)
    local words = {}
    for w in string.gmatch(norm(string.lower(raw)), "%S+") do words[#words + 1] = w end
    if #words == 0 then S.view = S.dest_all or {}; S.sel = 0; show(); return end
    local scored = {}
    local k = 0
    for _, e in ipairs(S.dest_all or {}) do
        k += 1
        local f = fuzzy(e, words)
        if f then scored[#scored + 1] = { e = e, s = f + 200 - k } end
    end
    table.sort(scored, function(a, b) return a.s > b.s end)
    local list = {}
    for i = 1, math.min(#scored, 40) do list[i] = scored[i].e end
    S.view = list
    S.sel = 0
    show()
    -- And any folder at all, by name (fzf over the folders of the index).
    local seq = (S.dest_seq or 0) + 1
    S.dest_seq = seq
    fzf_rank(words, true, 200, function(pool)
        if S.dest_seq ~= seq or S.mode ~= "dest" then return end
        local have = {}
        for _, e in ipairs(list) do have[e.path] = true end
        local more = {}
        for _, e in ipairs(pool) do
            if not have[e.path] and not (S.reg and S.reg.set[e.path]) then more[#more + 1] = { e = e, s = (fuzzy(e, words) or 0) + personal(e, raw) } end
        end
        table.sort(more, function(a, b) return a.s > b.s end)
        for _, x in ipairs(more) do list[#list + 1] = x.e end
        S.view = list
        show()
    end)
end
local function trash(list, then_)
    if #list == 0 then return end
    local args = { "trash", "--" }
    for _, pth in ipairs(list) do args[#args + 1] = pth end
    run("gio", args, function(_, code)
        if code == 0 then table.insert(S.undo, { kind = "trash", paths = list }) end
        toast(code == 0 and ("Moved " .. n_items(#list) .. " to the Trash · u undoes") or "Could not move it to the Trash")
        if then_ then then_() end
        after_change()
    end)
end
local function undo()
    local u = table.remove(S.undo)
    if not u then toast("Nothing to undo"); return end
    if u.kind == "rename" then
        run("mv", { "-n", "--", u.to, u.from }, function(_, code)
            toast(code == 0 and ("Undid rename · " .. base_of(u.from)) or "Could not undo the rename")
            after_change(u.from)
        end)
    elseif u.kind == "move" then
        local i = 0
        local function step()
            i += 1
            local m = u.pairs[i]
            if not m then toast("Moved back " .. n_items(#u.pairs)); after_change(); return end
            run("mv", { "-n", "--", m.dst, m.src }, function() step() end)
        end
        step()
    elseif u.kind == "copy" or u.kind == "new" then
        -- What this made (a copy, a new file or folder, an archive): gone again.
        local list = u.made or { u.path }
        local args = { "-rf", "--" }
        for _, p in ipairs(list) do args[#args + 1] = p end
        run("rm", args, function(_, code)
            toast(code == 0 and ("Undid · " .. n_items(#list) .. " removed") or "Could not undo it")
            after_change()
        end)
    elseif u.kind == "trash" then
        -- Back from the Trash: each found by where it came from.
        run("gio", { "list", "-a", "trash::orig-path", "trash://" }, function(out)
            local want = {}
            for _, p in ipairs(u.paths) do want[p] = true end
            local back = {}
            for l in string.gmatch(out or "", "[^\n]+") do
                local name, orig = string.match(l, "^(%S+)%s.-trash::orig%-path=(.+)$")
                if name and orig and want[orig] then back[#back + 1] = "trash:///" .. name; want[orig] = nil end
            end
            if #back == 0 then toast("Not in the Trash any more"); return end
            local i = 0
            local function step()
                i += 1
                if not back[i] then toast("Restored " .. n_items(#back)); after_change(u.paths[1]); return end
                run("gio", { "trash", "--restore", back[i] }, function() step() end)
            end
            step()
        end)
    end
end

-- r, a, A, and the rest that need a name: the field rising over the list.
local prompt_kind, prompt_for = nil, nil
local function ask(kind, label, prefill, target)
    prompt_kind, prompt_for = kind, target
    text.fnd_prompt_label = label
    text.fnd_in = prefill or ""
    fact.fnd_prompting = true
end
on("fnd_prompt_ok", function()
    local name = string.gsub(string.gsub(text.fnd_in or "", "^%s+", ""), "%s+$", "")
    local kind, e = prompt_kind, prompt_for
    prompt_kind, prompt_for = nil, nil
    if kind == "goto" then
        if name ~= "" then
            local p = untilde(name)
            exists_dir(p, function(yes)
                if yes then go(p) else toast("No folder " .. name) end
            end)
        end
        return
    end
    if name == "" or string.find(name, "/", 1, true) then toast("A name, without a /"); return end
    if kind == "rename" and e then
        if name == e.name then return end
        local to = join(e.parent, name)
        run("mv", { "-n", "--", e.path, to }, function(_, code)
            toast(code == 0 and ("Renamed to " .. name) or "Could not rename it")
            if code == 0 then
                table.insert(S.undo, { kind = "rename", from = e.path, to = to })
                if AR.items[e.path] then AR.items[to] = AR.items[e.path]; AR.items[e.path] = nil end
                for k, p in ipairs(store.pins) do if p == e.path then store.pins[k] = to end end
                save()
            end
            after_change(name)
        end)
    elseif kind == "folder" or kind == "file" then
        local p = join(S.cwd, name)
        run(kind == "folder" and "mkdir" or "touch", { "--", p }, function(_, code)
            if code == 0 then table.insert(S.undo, { kind = "new", path = p }) end
            toast(code == 0 and ("Made " .. name) or "Could not make it")
            after_change(name)
        end)
    elseif kind == "zip" then
        local list = e
        local out = join(S.cwd, (string.match(name, "%.%w+$") and name or (name .. ".zip")))
        local args = { "-a", "-cf", out, "-C", S.cwd, "--" }
        for _, p in ipairs(list) do args[#args + 1] = base_of(p) end
        toast("Compressing…")
        run("bsdtar", args, function(_, code)
            if code == 0 then table.insert(S.undo, { kind = "new", path = out }) end
            toast(code == 0 and ("Made " .. base_of(out)) or "Could not compress it")
            after_change(out)
        end)
    end
end)

local function extract(e)
    if not e or e.dir then return end
    local stem = string.gsub(string.gsub(e.name, "%.tar%.%w+$", ""), "%.%w+$", "")
    local taken = {}
    for _, x in ipairs(S.entries) do taken[x.name] = true end
    local dest = join(S.cwd, unique_in(S.cwd, stem, taken))
    toast("Extracting " .. e.name .. "…")
    run("mkdir", { "-p", "--", dest }, function()
        run("bsdtar", { "-xf", e.path, "-C", dest }, function(_, code)
            if code == 0 then table.insert(S.undo, { kind = "new", path = dest }) end
            toast(code == 0 and ("Extracted into " .. base_of(dest)) or "Could not extract it")
            after_change(dest)
        end)
    end)
end
-- O: the applications that open it, as a list in place of the folder (Enter launches).
local function open_with(e)
    if not e or e.head then return end
    run("xdg-mime", { "query", "filetype", e.path }, function(mime)
        mime = string.gsub(mime or "", "%s+$", "")
        if mime == "" then toast("Unknown kind of file"); return end
        run("gio", { "mime", mime }, function(out)
            local apps, seen = {}, {}
            local default = string.match(out or "", "Default application for “[^”]*”: (%S+)") or string.match(out or "", "Default application for \"[^\"]*\": (%S+)")
            for id in string.gmatch(out or "", "\n%s+(%S+%.desktop)") do
                if not seen[id] then seen[id] = true; apps[#apps + 1] = id end
            end
            if default and not seen[default] then table.insert(apps, 1, default) end
            if #apps == 0 then toast("Nothing is registered for " .. mime); return end
            local list = {}
            local pending = #apps
            for i, id in ipairs(apps) do
                local item = { name = string.gsub(id, "%.desktop$", ""), app = id, path = id, parent = mime, dir = false }
                list[i] = item
                run("sh", { "-c", "for d in ~/.local/share/applications /usr/share/applications /var/lib/flatpak/exports/share/applications; do f=\"$d/$1\"; [ -f \"$f\" ] && { grep -m1 '^Name=' \"$f\" | cut -d= -f2-; grep -m1 '^Icon=' \"$f\" | cut -d= -f2-; exit; }; done", "sh", id }, function(o)
                    local nm, ic = string.match(o or "", "^([^\n]*)\n?([^\n]*)")
                    if nm and nm ~= "" then item.name = nm .. (id == default and "  ·  default" or "") end
                    if ic and ic ~= "" then
                        item.icon_name = ic
                    end
                    pending -= 1
                    if pending == 0 then
                        S.with_target = e.path
                        S.mode = "with"
                        S.sel, S.off = 0, 0
                        S.view = list
                        show()
                    end
                end)
            end
        end)
    end)
end

-- ── keys ─────────────────────────────────────────────────────────────
-- The scene hands the logic every key while the files have the keyboard
-- (`fnd_kon`), except `i` and `/`, which the scene turns into typing itself so
-- not one letter of a fast search is lost. A key that waits for another (g y d
-- m ' f z) says so at the foot, which-key style, with what can follow.
local WHICH = {
    g = "gg top · G end · h ~ · d Downloads · D Documents · p Pictures · v Videos · m Music · r ~/github · c ~/.config · t Trash · / root · e Go to…",
    y = "yy pick up a copy · yp path · yd folder's path · yn name",
    d = "dd pick up to move · dD to Trash · dX delete for ever",
    m = "m + a–z: mark this folder (then ' + that letter)",
    f = "f + a letter: the next name starting with it (; next · , back)",
    z = "zh hidden files · zp preview · zs sort · zg grid",
}
local GPLACES = { h = HOME, d = HOME .. "/Downloads", D = HOME .. "/Documents", p = HOME .. "/Pictures", v = HOME .. "/Videos", m = HOME .. "/Music",
    r = HOME .. "/github", c = HOME .. "/.config", t = HOME .. "/.local/share/Trash/files", slash = "/", asciitilde = HOME }
local function set_pre(p)
    S.pre = p
    fact.fnd_pre = p ~= nil
    if p == "'" then
        local letters = {}
        for l, path in pairs(store.marks) do letters[#letters + 1] = l .. " " .. tilde(path) end
        table.sort(letters)
        text.fnd_pending = "' + a letter: " .. (#letters > 0 and table.concat(letters, " · ") or "no marks yet (m + a letter makes one)") .. " · '' back"
    else
        text.fnd_pending = p and WHICH[p] or ""
    end
end
local function move(d)
    help_on = false; fact.fnd_help_on = false; S.pv_for = nil
    local n = #S.view
    if n == 0 then return end
    local was = S.sel
    S.sel = math.clamp(S.sel + d, 0, n - 1)
    -- (section headers are stepped over)
    if S.view[S.sel + 1] and S.view[S.sel + 1].head then
        S.sel = math.clamp(S.sel + (d >= 0 and 1 or -1), 0, n - 1)
    end
    if was ~= S.sel or S.visual then show() end
end
local function find_char(ch, dir)
    local n = #S.view
    if n == 0 or not ch then return end
    ch = string.lower(ch)
    for k = 1, n do
        local i = (S.sel + dir * k) % n
        local e = S.view[i + 1]
        if e and not e.head and string.sub(e.low_name, 1, #ch) == ch then S.sel = i; show(); return end
    end
end
local function page() return S.grid and S.mode == "dir" and math.max(1, S.cols) * math.max(1, (S.grows or 3) - 1) or math.max(1, (S.mode == "dir" and S.rows or S.jrows) // 2) end
local function close_all()
    if fact.fnd_win and not (fact.app == "fnd" or (fact.expanded and fact.panel == "fnds")) then fact.fnd_win = false; return end
    if fact.app == "fnd" then fact.app = "none" elseif fact.expanded and fact.panel == "fnds" then fact.expanded = false end
end
local function pv_toggle()
    S.pv_for = nil
    fact.fnd_pv_on = not fact.fnd_pv_on
    store.preview = fact.fnd_pv_on
    save()
    show()
end
local function grid_toggle()
    S.grid = not S.grid
    fact.fnd_grid = S.grid
    store.grid = S.grid
    save()
    S.off = 0
    show()
end
local function hidden_toggle()
    S.pv_for = nil
    S.hidden = not S.hidden
    store.hidden = S.hidden
    save()
    toast(S.hidden and "Showing hidden files" or "Hiding hidden files")
    local keep = S.view[S.sel + 1] and S.view[S.sel + 1].path
    apply_filter()
    S.sel = 0
    if keep then for i, e in ipairs(S.view) do if e.path == keep then S.sel = i - 1 end end end
    show()
end
local function sort_step(d)
    if d < 0 then S.sort_rev = not S.sort_rev else S.sort_i = S.sort_i % #SORTS + 1; S.sort_rev = false end
    store.sort, store.sort_rev = SORTS[S.sort_i], S.sort_rev
    save()
    local keep = S.view[S.sel + 1] and S.view[S.sel + 1].path
    apply_filter()
    S.sel = 0
    if keep then for i, e in ipairs(S.view) do if e.path == keep then S.sel = i - 1 end end end
    toast("Sorted by " .. string.lower(SORT_LABEL[SORTS[S.sort_i]]) .. (S.sort_rev and ", reversed" or ""))
    show()
end
local function history(dir)
    local from, to = dir < 0 and S.back or S.fwd, dir < 0 and S.fwd or S.back
    local d = table.remove(from)
    if not d then toast(dir < 0 and "Nothing further back" or "Nothing further forward"); return end
    table.insert(to, S.cwd)
    go(d, nil, "history")
end
local function up()
    if S.mode ~= "dir" then return end
    local par = parent_of(S.cwd)
    if not par then return end
    go(par, S.cwd)
end
local function detach()
    -- The card ↔ a window of its own, with everything as it is.
    if fact.fnd_win and not (fact.app == "fnd" or (fact.expanded and fact.panel == "fnds")) then
        fact.fnd_win = false
        if fact.app == "none" then fact.app = "fnd"; fact.expanded = false else fact.expanded = true; fact.panel = "fnds" end
    else
        if fact.app == "fnd" then fact.app = "none" elseif fact.expanded and fact.panel == "fnds" then fact.expanded = false end
        fact.fnd_win = true
    end
end
local HELP = table.concat({
    "Move      j k · gg G · Ctrl+d u · f<c> ; ,",
    "          l ⏎ into · h - up (to /) · ~ home",
    "History   H L back/forward · Ctrl+o · '' last",
    "Jump      1–9 pinned · M pin · m<a-z> mark",
    "          '<a-z> go there · g<letter> places",
    "          ge type a path · i search anywhere",
    "Search    words · .pdf · photos · week · >10mb",
    "          ~/path · \"inside files\" · Tab",
    "Filter    / this folder · Esc keeps · Esc clears",
    "Select    Space mark · v range · Esc clear",
    "Move      yy / dd pick up (copy / move)",
    "          walk anywhere: it comes along",
    "          p into the folder under the cursor",
    "          P here · > + a usual place · Esc down",
    "Files     u undo · dD Trash · dX for ever",
    "          Delete Trash · Shift+Delete for ever",
    "          r rename",
    "          a file · A folder · x extract · X zip",
    "Copy      yp path · yd folder · yn name",
    "Open      ⏎ · o open · O open with · e nvim",
    "          t tmux session · T tmux window",
    "View      w grid · zp preview · . hidden",
    "          s S sort · K look closer / play",
    "          [ ] seek a video · W window",
    "Close     q · Esc",
}, "\n")

local function normal_key(name, typed)
    -- A key waiting for its second.
    local pre = S.pre
    if pre then
        set_pre(nil)
        if name == "Escape" then return end
        if pre == "g" then
            if name == "g" then S.sel = 0; show(); return end
            if name == "e" then ask("goto", "GO TO", tilde(S.cwd) .. "/", nil); return end
            local place = GPLACES[name]
            if place then go(place) end
            return
        elseif pre == "y" then
            if name == "y" then take("copy") return end
            local e = S.view[S.sel + 1]
            local what = nil
            if name == "p" then what = e and e.path
            elseif name == "d" then what = S.cwd
            elseif name == "n" then what = e and e.name end
            if what then pcall(sys.call, "clipboard.set", what); toast("Copied " .. tilde(what)) end
            return
        elseif pre == "d" then
            if name == "d" then take("cut") return end
            if name == "D" then trash(chosen()) return end
            if name == "X" then
                local list = chosen()
                if #list == 0 then return end
                S.armed = { list = list, at = os.clock() }
                toast("Delete " .. n_items(#list) .. " for ever? X again to confirm")
                set_pre("dX")
                text.fnd_pending = "X: delete " .. n_items(#list) .. " for ever (no undo) · anything else cancels"
                return
            end
            return
        elseif pre == "dX" then
            if name == "X" and S.armed then
                local list = S.armed.list
                S.armed = nil
                local args = { "-rf", "--" }
                for _, p in ipairs(list) do args[#args + 1] = p end
                run("rm", args, function(_, code)
                    toast(code == 0 and ("Deleted " .. n_items(#list)) or "Could not delete it")
                    after_change()
                end)
            else
                S.armed = nil
                toast("Not deleted")
            end
            return
        elseif pre == "m" then
            local l = typed and string.match(typed, "^%a$")
            if l then
                store.marks[l] = S.cwd
                save()
                toast("Mark '" .. l .. " · " .. tilde(S.cwd))
                show()
            end
            return
        elseif pre == "'" then
            if name == "apostrophe" or name == "grave" then
                if S.prev_dir then go(S.prev_dir) end
                return
            end
            local l = typed and string.match(typed, "^%a$")
            local p = l and store.marks[l]
            if p then go(p) elseif l then toast("No mark '" .. l) end
            return
        elseif pre == "f" or pre == "F" then
            if typed and #typed > 0 then S.last_f = typed; find_char(typed, pre == "f" and 1 or -1) end
            return
        elseif pre == "z" then
            if name == "h" then hidden_toggle() elseif name == "p" then pv_toggle() elseif name == "s" then sort_step(1) elseif name == "g" then grid_toggle() end
            return
        end
        return
    end

    local e = S.view[S.sel + 1]
    local grid = S.grid and S.mode == "dir"
    local cols = grid and math.max(1, S.cols) or 1
    -- Looking closer at a picture: its own keys.
    if fact.fnd_view then
        if name == "Escape" or name == "K" or name == "q" or name == "v" then pv_reset()
        elseif name == "plus" or name == "equal" or name == "k" and false then pv_zoom_to(PV.z * 1.25)
        elseif name == "J" or name == "minus" then pv_zoom_to(PV.z * 0.8)
        elseif name == "K" then pv_zoom_to(PV.z * 1.25)
        elseif name == "h" or name == "Left" then PV.px += 80; pv_view()
        elseif name == "l" or name == "Right" then PV.px -= 80; pv_view()
        elseif name == "k" or name == "Up" then PV.py += 80; pv_view()
        elseif name == "j" or name == "Down" then PV.py -= 80; pv_view()
        elseif name == "0" then pv_zoom_to(1)
        elseif name == "w" then pv_zoom_to(math.max(1, VW / math.max(1, fact.pv_iw))); if PV.doc then PV.py = math.huge end; pv_view()
        elseif name == "Ctrl+d" then PV.py -= 240; pv_view()
        elseif name == "Ctrl+u" then PV.py += 240; pv_view()
        elseif name == "G" then PV.py = -math.huge; pv_view()
        elseif name == "g" then PV.py = math.huge; pv_view() end
        return
    end
    if name == "j" or name == "Down" then move(grid and cols or 1)
    elseif name == "k" or name == "Up" then move(grid and -cols or -1)
    elseif grid and name == "Right" then move(1)
    elseif grid and name == "Left" then move(-1)
    elseif name == "l" or name == "Return" or (name == "Right" and not grid) then
        if S.mode == "jump" and e and not e.dir and name == "l" then reveal(e) else enter(e) end
    elseif name == "h" or name == "BackSpace" or name == "minus" or (name == "Left" and not grid) then
        if S.mode ~= "dir" then S.mode = "dir"; text.fq = ""; fact.fq_empty = true; apply_filter(); show() else up() end
    elseif name == "G" then S.sel = #S.view - 1; show()
    elseif name == "g" then set_pre("g")
    elseif name == "Ctrl+d" then move(page())
    elseif name == "Ctrl+u" then move(-page())
    elseif name == "Ctrl+f" or name == "Next" then move(page() * 2)
    elseif name == "Ctrl+b" or name == "Prior" then move(-page() * 2)
    elseif name == "Home" then S.sel = 0; show()
    elseif name == "End" then S.sel = #S.view - 1; show()
    elseif name == "H" or name == "Alt+Left" or name == "Ctrl+o" then history(-1)
    elseif name == "L" or name == "Alt+Right" or name == "Ctrl+i" then history(1)
    elseif name == "asciitilde" then go(HOME)
    elseif string.match(name, "^[1-9]$") then
        local p = store.pins[tonumber(name)]
        if p then
            if is_dir(p) then go(p) else launch(entry(p, false)) end
        else toast("No pin " .. name .. " · M pins what is under the cursor") end
    elseif name == "M" then
        local target = e and not e.head and e.path or S.cwd
        local at = table.find(store.pins, target)
        if at then table.remove(store.pins, at); toast("Unpinned " .. base_of(target))
        elseif #store.pins >= 9 then toast("Nine pins already · M on one unpins it")
        else table.insert(store.pins, target); toast("Pinned " .. base_of(target) .. " as " .. #store.pins) end
        save()
        show()
    elseif name == "m" then set_pre("m")
    elseif name == "apostrophe" or name == "grave" then set_pre("'")
    elseif name == "f" then set_pre("f")
    elseif name == "F" then set_pre("F")
    elseif name == "semicolon" then find_char(S.last_f, 1)
    elseif name == "comma" then find_char(S.last_f, -1)
    elseif name == "z" then set_pre("z")
    elseif name == "y" then set_pre("y")
    elseif name == "d" then set_pre("d")
    elseif name == "p" then paste(false)
    elseif name == "P" then paste(true)
    elseif name == "greater" then dest_pick("cut")
    elseif name == "plus" then dest_pick("copy")
    elseif name == "u" then undo()
    elseif name == "space" then
        if e and not e.head and not e.app then
            if S.marked[e.path] then S.marked[e.path] = nil; S.nmarks -= 1 else S.marked[e.path] = true; S.nmarks += 1 end
            move(1)
            show()
        end
    elseif name == "v" or name == "V" then
        if S.visual then S.visual = nil; show()
        else
            S.visual = S.sel
            if e and not e.head and not S.marked[e.path] then S.marked[e.path] = true; S.nmarks += 1 end
            show()
        end
    elseif name == "Delete" then trash(chosen())
    elseif name == "Shift+Delete" then
        local list = chosen()
        if #list > 0 then
            S.armed = { list = list }
            toast("Delete " .. n_items(#list) .. " for ever? X to confirm")
            set_pre("dX")
            text.fnd_pending = "X: delete " .. n_items(#list) .. " for ever (no undo) · anything else cancels"
        end
    elseif name == "Ctrl+a" then
        S.marked, S.nmarks = {}, 0
        for _, x in ipairs(S.view) do if not x.head and not x.app then S.marked[x.path] = true; S.nmarks += 1 end end
        show()
    elseif name == "Escape" then
        if help_on then help_on = false; fact.fnd_help_on = false; S.pv_for = nil; show()
        elseif S.visual then S.visual = nil; show()
        elseif S.mode == "dest" then S.mode = "dir"; text.fq = ""; fact.fq_empty = true; apply_filter(); show()
        elseif S.reg then S.reg = nil; toast("Put down"); show()
        elseif S.nmarks > 0 then unmark(); show()
        elseif S.mode ~= "dir" then S.mode = "dir"; text.fq = ""; fact.fq_empty = true; apply_filter(); show()
        elseif S.filter ~= "" then
            local keep = e and e.path
            S.filter = ""; text.fq = ""; fact.fq_empty = true
            apply_filter()
            if keep then for i, x in ipairs(S.view) do if x.path == keep then S.sel = i - 1 end end end
            show()
        elseif not fact.fnd_win or fact.app == "fnd" or (fact.expanded and fact.panel == "fnds") then close_all() end
    elseif name == "q" then close_all()
    elseif name == "r" then if e and not e.head and not e.app then ask("rename", "RENAME", e.name, e) end
    elseif name == "a" then if S.mode == "dir" then ask("file", "NEW FILE", "", nil) end
    elseif name == "A" then if S.mode == "dir" then ask("folder", "NEW FOLDER", "", nil) end
    elseif name == "x" then if e then extract(e) end
    elseif name == "X" then
        local list = chosen()
        if #list > 0 then ask("zip", "COMPRESS AS", (#list == 1 and string.gsub(base_of(list[1]), "%.%w+$", "") or "Archive") .. ".zip", list) end
    elseif name == "s" then sort_step(1)
    elseif name == "S" then sort_step(-1)
    elseif name == "period" then hidden_toggle()
    elseif name == "w" then grid_toggle()
    elseif name == "K" then
        if S.pv_video and fact.pv_kind == 2 then video_toggle() elseif fact.pv_kind == 2 then fact.fnd_view = true end
    elseif name == "bracketleft" then if fact.fnd_vplay then pcall(sys.call, "video.seek", math.max(0, (S.vpos or 0) - 5)) end
    elseif name == "bracketright" then if fact.fnd_vplay then pcall(sys.call, "video.seek", (S.vpos or 0) + 5) end
    elseif name == "W" then detach()
    elseif name == "o" then if e then if e.dir then go(e.path) else launch(e) end end
    elseif name == "O" then open_with(e)
    elseif name == "e" then
        if e and not e.head then ar_visit(e.path); done(); tmux_window(e.dir and e.path or e.parent, { "nvim", e.path }) end
    elseif name == "t" then
        local dir = e and (e.dir and e.path or e.parent) or S.cwd
        ar_visit(dir); done()
        run("tmux", { "run-shell", "sesh connect " .. q(dir) }, function(_, code)
            if code == 0 then to_terminal() else toast("No tmux session is running") end
        end)
    elseif name == "T" then
        local dir = e and (e.dir and e.path or e.parent) or S.cwd
        ar_visit(dir); done(); tmux_window(dir)
    elseif name == "question" then
        help_on = not help_on
        fact.fnd_help_on = help_on
        if help_on then
            pv_gen += 1
            text.fnd_help_text = HELP
            text.pv_name = "Keys"
            text.pv_meta = "Everything the files do"
            fact.pv_kind = 5
        else show() end
    elseif name == "Ctrl+Shift+H" or name == "Ctrl+H" then
        -- Beside WhatsApp: what is marked (or under the cursor) put over its field to send.
        local paths = {}
        for _, p in ipairs(chosen()) do
            local x = S.by_path and S.by_path[p]
            if not ((x and x.dir) or (not x and is_dir(p))) then paths[#paths + 1] = p end
        end
        if #paths == 0 then toast("A folder can't be sent: mark files in it (Space)"); return end
        if not wa_hook.stage then return end
        for _, p in ipairs(paths) do wa_hook.stage(p) end
        unmark()
        show()
        fact.side_focus = false
    end
end

-- Typing in the field: the search (i) or the folder's filter (/).
local function insert_key(name)
    if name == "Escape" then
        fact.fnd_insert = false
        focus()
        if fact.fnd_qkind == 1 and (text.fq or "") == "" then S.mode = "dir"; apply_filter(); show() end
        if fact.fnd_qkind == 3 then S.mode = "dir"; text.fq = ""; fact.fq_empty = true; apply_filter(); show() end
        return true
    elseif name == "Ctrl+j" or name == "Down" or name == "Ctrl+n" then move(1); return true
    elseif name == "Ctrl+k" or name == "Up" or name == "Ctrl+p" then move(-1); return true
    elseif name == "Tab" and fact.fnd_qkind == 3 then
        -- Choosing where to put it: go there instead, still carrying it.
        local e = S.view[S.sel + 1]
        if e then fact.fnd_insert = false; focus(); go(e.path) end
        return true
    elseif name == "Tab" then
        -- A path: complete it to the one under the cursor; otherwise, the next.
        local e = S.view[S.sel + 1]
        local raw = text.fq or ""
        if e and (string.sub(raw, 1, 1) == "/" or string.sub(raw, 1, 1) == "~") then
            local p = tilde(e.path) .. (e.dir and "/" or "")
            if string.sub(raw, 1, 1) == "/" then p = e.path .. (e.dir and "/" or "") end
            text.fq = p
            fact.fq_empty = false
            search(p)
        else move(1) end
        return true
    elseif name == "Ctrl+l" then
        local e = S.view[S.sel + 1]
        if e then reveal(e) end
        return true
    end
    return false
end
-- The keyboard arriving (the window clicked or focused): no field takes it until `i` or `/`.
on("focus", function()
    if fact.fnd_kon and not fact.fnd_insert and not fact.fnd_prompting then focus() end
end)
on("key", function(name, typed)
    if not fact.fnd_kon then return end
    if fact.fnd_prompting then return end
    if fact.fnd_insert then insert_key(name); return end
    -- (i and / are the scene's, when nothing waits for a second key)
    if not S.pre and (name == "i" or name == "slash") then return end
    normal_key(name, typed)
end)

-- The field: what is typed is searched (i) or narrows the folder (/).
on("text:fq", function()
    local raw = text.fq or ""
    fact.fq_empty = raw == ""
    if fact.fnd_qkind == 3 then dest_filter(raw); return end
    if fact.fnd_qkind == 2 then
        if S.mode ~= "dir" then S.mode = "dir" end
        S.filter = raw
        local keep = S.view[S.sel + 1]
        apply_filter()
        S.sel = 0
        if raw == "" and keep then for i, e in ipairs(S.view) do if e.path == keep.path then S.sel = i - 1 end end end
        show()
    else
        S.mode = "jump"
        search(raw)
    end
end)
on("submit:fq", function()
    local e = S.view[S.sel + 1]
    if fact.fnd_qkind == 2 then
        -- Enter in the filter: into it (or open it), and the filter goes.
        fact.fnd_insert = false
        focus()
        S.filter = ""
        if e then enter(e) else apply_filter(); show() end
        return
    end
    if e then enter(e) end
end)
-- The search button: as `i`.
on("fnd_search_click", function()
    fact.fnd_qkind = 1
    fact.fnd_insert = true
    focus("fq")
    note_cursor()
    S.mode = "jump"
    text.fq = ""
    fact.fq_empty = true
    search("")
end)
-- The scene opened the field: a search starts from what AccessRank expects.
on("fact:fnd_insert", function(v)
    if v and fact.fnd_qkind == 1 and S.mode ~= "jump" then
        note_cursor()
        S.mode = "jump"
        text.fq = ""
        fact.fq_empty = true
        search("")
        if os.time() - IX.at > 600 then index() end
    elseif v and fact.fnd_qkind == 2 then
        S.filter = text.fq or ""
    end
end)

-- ── the mouse ────────────────────────────────────────────────────────
on("fnd_open_row", function(i)
    local k = S.off + i
    if not S.view[k + 1] then return end
    S.sel = k
    enter(S.view[k + 1])
end)
-- A click chooses; a second on the same one within 400 ms opens it (no drag ever opens anything).
local click_at = nil
on("fnd_pick_row", function(i)
    local k = S.off + i
    local e = S.view[k + 1]
    if not e or e.head then return end
    if click_at == k then
        click_at = nil
        S.sel = k
        enter(e)
        return
    end
    click_at = k
    after(400, function() if click_at == k then click_at = nil end end)
    if S.sel ~= k then S.sel = k; show() end
end)
on("fnd_hbtn", function(k)
    if k == 1 then history(-1) elseif k == 2 then up() elseif k == 3 then pv_toggle() elseif k == 4 then detach() elseif k == 5 then normal_key("question") end
end)
on("fnd_mark_row", function(i)
    local e = S.view[S.off + i + 1]
    if not e or e.head then return end
    if S.marked[e.path] then S.marked[e.path] = nil; S.nmarks -= 1 else S.marked[e.path] = true; S.nmarks += 1 end
    S.sel = S.off + i
    show()
end)
on("fnd_rail", function(i)
    local p = rail_paths[i + 1]
    if not p then return end
    if type(p) == "table" and p.drive then
        local d = p.drive
        if d.mount then go(d.mount) return end
        toast("Mounting " .. d.name .. "…")
        run("udisksctl", { "mount", "-b", d.dev }, function(out, code)
            local mp = string.match(out or "", " at (/[^%s]+)")
            if code == 0 and mp then read_drives(); go(mp) else toast("Could not mount " .. d.name) end
        end)
        return
    end
    go(p)
end)
on("fnd_eject", function(i)
    local p = rail_paths[i + 1]
    if type(p) ~= "table" or not p.drive then return end
    local d = p.drive
    if string.sub(S.cwd, 1, #(d.mount or "\0")) == d.mount then go(HOME) end
    run("udisksctl", { "unmount", "-b", d.dev }, function(_, code)
        toast(code == 0 and ("Ejected " .. d.name) or ("Could not eject " .. d.name))
        read_drives(function() if S.open then show() end end)
    end)
end)
on("fnd_crumb", function(i)
    local p = crumb_paths[i + 1]
    if p == nil then return end
    if p == false then return end
    if i + 1 == #crumb_paths then pcall(sys.call, "clipboard.set", p); toast("Copied " .. tilde(p)); return end
    go(p)
end)
on("fnd_scroll", function(w)
    local step = (S.grid and S.mode == "dir") and math.max(1, S.cols) or 1
    local rows = S.grid and S.mode == "dir" and math.max(1, S.cols) * math.max(1, S.grows or 3) or math.max(1, S.mode == "dir" and S.rows or S.jrows)
    S.off = math.clamp(S.off + (w > 0 and -step or step), 0, math.max(0, #S.view - rows))
    if S.grid and S.mode == "dir" then S.off -= S.off % step end
    S.sel = math.clamp(S.sel, S.off, S.off + rows - 1)
    show()
end)
on("fnd_help", function() normal_key("question") end)
on("fnd_view_as", function(v)
    S.pv_for = nil
    local list = v == 0 or (v < 0 and not fact.pvd_list)
    fact.pvd_list = list
    store.pv_view = list and "list" or "icons"
    save()
    show()
end)
on("fnd_grid_as", function(v) if (v == 1) ~= S.grid then grid_toggle() end end)
on("fnd_sort_next", function() sort_step(1) end)
on("fnd_detach", function() detach() end)
on("fnd_back", function() history(-1) end)
on("fnd_forward", function() history(1) end)
on("fnd_up", function() up() end)
on("fnd_yank", function()
    local e = S.view[S.sel + 1]
    if e then pcall(sys.call, "clipboard.set", e.path); toast("Copied " .. tilde(e.path)) end
end)
on("fq_clear", function() normal_key("Escape") end)
-- The preview, looked at closer.
on("pv_click", function()
    if not video_toggle() and fact.pv_kind == 2 then fact.fnd_view = true; PV.gx, PV.gy = PV.px, PV.py end
end)
on("fnd_vseek", function(t) if fact.fnd_vplay then pcall(sys.call, "video.seek", math.max(0, t)) end end)
sys.watch("video", function(v) S.vpos = v and v.position or 0 end)
on("pv_zoom", function(f) pv_zoom_to(PV.z * f) end)
on("pv_fit", function() pv_zoom_to(1) end)
local grab_x, grab_y = 0, 0
on("pv_grab", function() grab_x, grab_y = PV.px, PV.py end)
on("pv_drag_x", function(d) PV.px = grab_x + d; pv_view() end)
on("pv_drag_y", function(d) PV.py = grab_y + d; pv_view() end)

-- Dropped on the files (from another program, or the shelf): copied into the
-- folder showing, or into the folder row it was let go on.
local function dropped(data, into)
    local list = from_uris(data)
    if #list == 0 then return end
    local dest = into or S.cwd
    put(list, dest, "copy", function(ok_n, bad, first)
        toast((bad == 0 and "Copied " or ("Copied " .. ok_n .. ", failed " .. bad .. " · ")) .. n_items(ok_n) .. " into " .. base_of(dest))
        after_change(dest == S.cwd and first or nil)
    end)
end
S.dropped = dropped
-- Where a drop lands: the folder row, place or crumb under the pointer, else here.
-- Dragged out of these very files and let go here: moved (as within one file
-- manager); from another program: copied.
local own_drag = nil
on("fnd_carried", function(i)
    local e = S.view[S.off + i + 1]
    if not e then return end
    local set = {}
    if S.marked[e.path] and S.nmarks > 1 then for p in pairs(S.marked) do set[p] = true end else set[e.path] = true end
    own_drag = { set = set, at = os.time() }
end)
local function landed(data, dest)
    local list = from_uris(data)
    if #list == 0 or not dest then return end
    local mine = own_drag and os.time() - own_drag.at < 120
    if mine then for _, p in ipairs(list) do if not own_drag.set[p] then mine = false end end end
    own_drag = nil
    local mode = mine and "move" or "copy"
    put(list, dest, mode, function(ok_n, bad, first)
        if ok_n > 0 then dest_learn(list, dest) end
        toast((mode == "move" and "Moved " or "Copied ") .. n_items(ok_n) .. (dest == S.cwd and " here" or (" into " .. base_of(dest))) .. (bad > 0 and (" · " .. bad .. " failed") or "") .. " · u undoes")
        unmark()
        after_change(dest == S.cwd and first or nil)
    end)
end
local function row_dest()
    local e = (fact.fnd_hover or -1) >= 0 and S.view[S.off + fact.fnd_hover + 1]
    if e and e.dir and S.mode == "dir" then return e.path end
    return S.mode == "dir" and S.cwd or nil
end
on("drop:row", function(data) landed(data, row_dest()) end)
on("drop:tz", function(data) landed(data, row_dest()) end)
on("drop:fnd_list", function(data) landed(data, S.mode == "dir" and S.cwd or nil) end)
on("drop:fdrop", function(data) landed(data, S.mode == "dir" and S.cwd or nil) end)
on("drop:rz", function(data)
    local p = rail_paths[(fact.fnd_rhover or -1) + 1]
    if type(p) == "string" then landed(data, p) elseif type(p) == "table" and p.drive and p.drive.mount then landed(data, p.drive.mount) end
end)
on("drop:cz", function(data)
    local p = crumb_paths[(fact.fnd_chover or -1) + 1]
    if p then landed(data, p) end
end)
-- Held over a folder (a row or a place) while dragging: it opens under the pointer.
on("fnd_spring", function(i)
    local e = S.view[S.off + i + 1]
    if e and e.dir and S.mode == "dir" then go(e.path) end
end)
on("fnd_rspring", function(i)
    local p = rail_paths[i + 1]
    if type(p) == "string" and p ~= S.cwd then go(p) end
end)

on("fnd_raise", function() run(SCRIPTS .. "wm.sh", { "focus-class", "lumen.files" }, nil, { output = false }) end)
-- From outside: `lumen --say island "text fnd_ext PATH"` (xdg-open of a folder,
-- a browser's "show in folder"): the window, there; a file: its folder, on it.
on("text:fnd_ext", function(v)
    local p = untilde(string.gsub(string.gsub(v or "", "^%s+", ""), "%s+$", ""))
    if p == "" then p = S.cwd end
    p = string.gsub(p, "^file://", "")
    p = string.gsub(p, "%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end)
    run("test", { "-d", p }, function(_, code)
        if code == 0 then go(p) else go(parent_of(p) or HOME, p) end
        if fact.app == "fnd" then fact.app = "none" elseif fact.expanded and fact.panel == "fnds" then fact.expanded = false end
        fact.fnd_win = true
        run(SCRIPTS .. "wm.sh", { "focus-class", "lumen.files" }, nil, { output = false })
    end)
end)

-- What the scene measures: the list's room, in rows (and the grid's cells).
local function measure()
    local lh, lw = fact.fnd_lh or 456, fact.fnd_lw or 480
    local new_rows = math.max(3, math.floor((lh + 2) / 32))
    local new_jrows = math.max(3, math.floor((lh + 2) / 46))
    local new_cols = math.max(1, math.floor(lw / 116))
    local new_grows = math.max(1, math.floor((lh + 4) / 132))
    local changed = new_rows ~= S.rows or new_jrows ~= S.jrows or new_cols ~= S.cols or new_grows ~= S.grows
    S.rows, S.jrows, S.cols, S.grows = new_rows, new_jrows, new_cols, new_grows
    fact.fnd_cols = new_cols
    return changed
end
local function pv_width()
    local w = math.floor((fact.fnd_pvw or 660) - 36)
    local hh = math.floor((fact.fnd_pvh or 520) - 120)
    if (w ~= VW or hh ~= VH) and w > 0 and hh > 0 then
        VW, VH = w, hh
        fit_pic(pic_w, pic_h)
        pv_reset()
        if S.open then preview(S.view[S.sel + 1]) end
    end
end
on("fact:fnd_lh", function() if measure() and S.open then show() end end)
on("fact:fnd_lw", function() if measure() and S.open then show() end end)
on("fact:fnd_pvw", pv_width)
on("fact:fnd_pvh", pv_width)
measure()

-- ── coming and going ─────────────────────────────────────────────────
-- Reopened within five minutes, the files are where they were left; later, ~.
local RESUME = 5 * 60
local function wanted() return fact.app == "fnd" or (fact.expanded and fact.panel == "fnds") or fact.fnd_win end
local function arrive()
    S.open = true
    unmark()
    measure()
    pv_width()
    read_drives()
    local last = store.last
    if last and os.time() - (last.at or 0) < RESUME and last.cwd then
        S.cursor[last.cwd] = last.sel
        S.cwd = "\0"
        go(last.cwd, last.sel, "quiet")
    elseif S.cwd == "\0" or S.view[1] == nil or os.time() - (store.last and store.last.at or 0) >= RESUME then
        S.back, S.fwd = {}, {}
        S.cwd = "\0"
        go(HOME, nil, "quiet")
    else
        watch_folder(S.cwd)
        S.reload(S.view[S.sel + 1] and S.view[S.sel + 1].path)
    end
    if os.time() - IX.at > 300 then index() end
end
local function leave()
    S.open = false
    video_stop()
    note_cursor()
    if S.monitor then kill(S.monitor); S.monitor = nil end
    if content_id then kill(content_id); content_id = nil end
    S.mode = "dir"
    S.filter = ""
    text.fq = ""
    fact.fq_empty = true
    fact.fnd_insert = false
    help_on = false
    fact.fnd_help_on = false; S.pv_for = nil
    set_pre(nil)
    local e = S.view[S.sel + 1]
    store.last = { cwd = S.cwd, sel = e and e.path, at = os.time() }
    save()
end
local function sync()
    local want = wanted()
    if want and not S.open then arrive() elseif not want and S.open then leave() end
end
on("fact:app", sync)
on("fact:panel", sync)
on("fact:expanded", sync)
on("fact:fnd_win", sync)

-- At start: the index, and the thumbnail and search caches warmed in the
-- background (at the lowest priority) so the first look is already quick.
after(4000, function() index() end)
after(90000, function()
    run("nice", { "-n", "19", "rga", "--files-with-matches", "-F", "zq0lumenwarm0qz", HOME .. "/Documents", HOME .. "/Downloads", HOME .. "/Desktop" }, nil, { output = false })
end)

-- What the shelf (shelf.luau) borrows: thumbnails, icons, and opening the files somewhere.
S.picture_of = function(e) local p, ar = picture_of(e, true); thumb_pump(); return p, ar end
S.entry = entry
S.icon_of = function(e) return ficon.of(e.name, e.dir, e.path) end
S.from_uris = from_uris
S.show_in_files = function(path)
    go(parent_of(path) or HOME, path)
    if not wanted() then fact.fnd_win = true end
end

return S
end
