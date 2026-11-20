--! The shelf (pages/shelf.plm), as Dropover on macOS: files dragged from any
--! program over the right capsule are held there, as references (nothing is
--! copied), until they are dragged out to where they go, or let go of. A text
--! or a link dropped there becomes a small file of its own, so it can be dragged
--! out like the rest. Kept across restarts (shelf.json); what has gone from the
--! disk meanwhile is dropped from it.
--!
--! `require("shelf")({ files = <finder.luau's state>, HOME = … })`.

return function(sh)
local files, HOME = sh.files, sh.HOME
local MAX = 12
local SNIPS = HOME .. "/.cache/lumen/shelf"
local items = {}          -- { path, name, size, mtime }

local function save()
    local list = {}
    for i, it in ipairs(items) do list[i] = it.path end
    pcall(sys.call, "files.write", "shelf.json", list)
end

local function show()
    local rows, all = {}, {}
    for i, it in ipairs(items) do
        local e = files.entry(it.path, it.dir, it.size, it.mtime)
        local pic, ar = files.picture_of(e)
        rows[i] = { name = it.name, ic = pic or files.icon_of(e), ar = pic and ar or 0, path = it.path }
        all[i] = it.path
    end
    model.shf = rows
    text.shf_all = table.concat(all, "\n")
    text.shf_top_path = rows[#rows] and rows[#rows].ic or ""
end
local prev_hook = files.on_thumb
files.on_thumb = function()
    if prev_hook then prev_hook() end
    if #items > 0 then show() end
end

-- What is known of each (size and time, for its thumbnail), then shown.
local function add(paths, then_)
    local have = {}
    for _, it in ipairs(items) do have[it.path] = true end
    local fresh = {}
    for _, p in ipairs(paths) do
        if not have[p] then have[p] = true; fresh[#fresh + 1] = p end
    end
    if #fresh == 0 then if then_ then then_() end return end
    local args = { "-L", "-c", "%F\t%s\t%Y\t%n", "--" }
    for _, p in ipairs(fresh) do args[#args + 1] = p end
    run("stat", args, function(out)
        for l in string.gmatch(out or "", "[^\n]+") do
            local kind, size, t, p = string.match(l, "^([^\t]+)\t(%d+)\t(%d+)\t(.+)$")
            if p then
                items[#items + 1] = { path = p, name = string.match(p, "([^/]+)$") or p, dir = kind == "directory", size = tonumber(size), mtime = tonumber(t) }
            end
        end
        while #items > MAX do table.remove(items, 1) end
        save()
        show()
        if then_ then then_() end
    end)
end

-- A text or a link let go on the shelf: a small file of its own.
local function snip(data, then_)
    local name
    local url = string.match(data, "^%s*(https?://%S+)%s*$")
    if url then
        local host = string.match(url, "^https?://([^/]+)") or "link"
        name = host .. " " .. os.date("%H.%M.%S") .. ".url"
        data = "[InternetShortcut]\nURL=" .. url .. "\n"
    else
        local first = string.gsub(string.sub(string.match(data, "^%s*([^\n]*)") or "Text", 1, 32), "[/%c]", " ")
        name = (first ~= "" and first or "Text") .. " " .. os.date("%H.%M.%S") .. ".txt"
    end
    local path = SNIPS .. "/" .. name
    run("mkdir", { "-p", SNIPS }, function()
        run("tee", { path }, function(_, code)
            if code == 0 then add({ path }, then_) end
        end, { input = data })
    end)
end

local function landed(data, mime)
    data = data or ""
    local paths = files.from_uris(data)
    local function opened()
        fact.shf_peek = true
        -- Shown a moment, then back into the capsule (unless the pointer is on it).
        after(2600, function() if not fact.shf_over then fact.shf_peek = false end end)
    end
    if #paths > 0 then add(paths, opened)
    elseif string.match(data, "%S") then snip(data, opened) end
end
-- Let go anywhere on the capsule or the shelf.
for _, z in ipairs({ "shf_z", "sz", "shf_all_z", "shf_x", "stat_z", "bat_z", "date_z", "mute_z", "shf_chip" }) do
    on("drop:" .. z, landed)
end

-- From a terminal or a script: `lumen --say island "text shf_add PATH"` (one path, or a file:// list).
on("text:shf_add", function(v)
    v = v or ""
    if string.sub(v, 1, 1) == "/" and not string.find(v, "\n") then v = "file://" .. v end
    landed(v)
end)

-- Opened by hovering the stack: once the pointer has been off it (and off the card) for a
-- moment, it goes back into the capsule.
local watching = false
local function watch_away()
    if watching then return end
    watching = true
    local misses = 0
    local id
    id = every(400, function()
        if not fact.shf_peek then watching = false; cancel(id); return end
        if fact.shf_over or fact.cap_over then misses = 0 else misses += 1 end
        if misses >= 2 then fact.shf_peek = false; watching = false; cancel(id) end
    end)
end
on("fact:shf_peek", function(v) if v then watch_away() end end)

on("shf_clear", function()
    items = {}
    save()
    show()
    fact.shf_peek = false
end)
on("shf_remove", function(i)
    if items[i + 1] then table.remove(items, i + 1); save(); show() end
    if #items == 0 then fact.shf_peek = false end
end)
on("shf_open_item", function(i)
    local it = items[i + 1]
    if not it then return end
    if it.dir then files.show_in_files(it.path .. "/.") else run("xdg-open", { it.path }, nil, { output = false }) end
end)

-- Back as it was, without what has gone from the disk meanwhile.
local kept = sys.ask("files.read", "shelf.json", "json")
if type(kept) == "table" and #kept > 0 then
    run("sh", { "-c", 'for p; do [ -e "$p" ] && printf "%s\\n" "$p"; done', "sh", table.unpack(kept) }, function(out)
        local list = {}
        for l in string.gmatch(out or "", "[^\n]+") do list[#list + 1] = l end
        add(list)
    end)
end
end
