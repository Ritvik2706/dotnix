-- Island logic: only what the scene can't know on its own.
--   · the cover: MPRIS gives `file://…` (browsers) or `https://…` (Spotify);
--     the scene can only paint a local path, so remote art is fetched once
--     per track into the scene's own folder.
--   · the transport buttons, passed on to the player.

local folder = sys.ask("files.folder")
-- The folder only exists once something is written to it; curl needs it for the cover.
sys.call("files.write", ".keep", "")
local version = 0
local last_art = nil

local function unescape(s)
    return (s:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end))
end

-- The artwork's colour, as the Dynamic Island tints its waveform: the most
-- vivid of its eight main colours (weighed by how much of it there is),
-- brightened so it reads on the glass. A grey cover keeps the island's teal.
local function tint_from(path, art)
    run("magick", { path, "-resize", "48x48", "-colors", "8", "-format", "%c", "histogram:info:-" }, function(out, code)
        if last_art ~= art then return end
        if code ~= 0 or not out then fact.art_tinted = false return end
        local best, br, bg, bb = 0, 0, 0, 0
        for count, r, g, b in out:gmatch("(%d+):%s*%(%s*([%d%.]+)%s*,%s*([%d%.]+)%s*,%s*([%d%.]+)") do
            r, g, b = tonumber(r) / 255, tonumber(g) / 255, tonumber(b) / 255
            local hi, lo = math.max(r, g, b), math.min(r, g, b)
            local sat = hi > 0 and (hi - lo) / hi or 0
            -- Vivid and not too dark; a little extra weight for what covers more.
            local score = sat * math.min(1, hi / 0.35) * tonumber(count) ^ 0.35
            if score > best then best, br, bg, bb = score, r, g, b end
        end
        local hi = math.max(br, bg, bb)
        if best <= 0 or hi <= 0 or (hi - math.min(br, bg, bb)) / hi < 0.2 then fact.art_tinted = false return end
        local lift = math.max(hi, 0.85) / hi
        fact.art_r, fact.art_g, fact.art_b = math.min(1, br * lift), math.min(1, bg * lift), math.min(1, bb * lift)
        fact.art_tinted = true
    end)
end

local function show(path)
    version += 1
    -- A versioned name reloads into the same atlas slot instead of taking new room.
    text.cover_path = path .. "?" .. version
    fact.has_art = true
    tint_from(path, last_art)
    -- Its shape, so it is shown whole: a square cover, a video's 16:9 frame.
    local art = last_art
    run("magick", { "identify", "-format", "%w %h\n", path .. "[0]" }, function(out)
        if last_art ~= art then return end
        local w, h = string.match(out or "", "(%d+) (%d+)")
        w, h = tonumber(w), tonumber(h)
        fact.art_aspect = (w and h and h > 0) and (w / h) or 1
    end)
end

local function cover(m)
    fact.has_player = (m and m.player or "") ~= ""
    local art = (m and m.art) or ""
    if art == last_art then return end
    last_art = art

    if art:sub(1, 7) == "file://" then
        show(unescape(art:sub(8)))
    elseif art:sub(1, 1) == "/" then
        show(art)
    elseif art:match("^https?://") and folder then
        local dest = folder .. "/cover"
        run("curl", { "-sfL", "--max-time", "6", "-o", dest, art }, function(_, code)
            -- A newer track may have arrived while this one downloaded.
            if code == 0 and last_art == art then show(dest) end
        end)
    else
        text.cover_path = ""
        fact.has_art = false
        fact.art_tinted = false
    end
end

sys.watch("media", cover)


on("toggle", function() sys.call("media.toggle") end)
on("next", function() sys.call("media.next") end)
on("previous", function() sys.call("media.previous") end)
on("seek_to", function(t) pcall(sys.call, "media.seek", t) end)

-- ── workspaces ──────────────────────────────────────────────────────
-- A workspace shows when it has windows or is the active one (empty ones take
-- no room, as in waybar).
local active_ws = 1
-- niri stacks workspaces vertically: the bar answers a switch in that direction.
-- Armed a moment after starting, so the first report of where we are isn't a switch.
-- (One table: the logic is at Luau's limit of 200 locals.)
local wsl = { niri = sys.ask("env", "NIRI_SOCKET") ~= nil, armed = false, last = nil }
after(500, function() fact.ws_vertical = wsl.niri; wsl.armed = true end)
sys.watch("workspaces", function(w)
    local busy = {}
    for _, d in ipairs(w.list) do
        if d.windows > 0 then busy[d.id] = true end
    end
    active_ws = w.active
    fact.ws_active = w.active
    if wsl.niri and wsl.armed and wsl.last and w.active ~= wsl.last and wsl.landed then wsl.landed(w) end
    wsl.last = w.active
    local count = 0
    for i = 1, 10 do
        local visible = busy[i] or i == w.active
        fact["ws." .. i .. ".there"] = visible
        if i == w.active then fact.ws_slot = count end
        if visible then count += 1 end
    end
    fact.ws_count = math.max(1, count)
end)

on("go", function(i) sys.call("workspaces.focus", i) end)
-- The wheel over the workspaces walks them, one notch a step, within 1..10.
on("ws_step", function(notches)
    local to = math.clamp(active_ws + (notches > 0 and 1 or -1), 1, 10)
    if to ~= active_ws then sys.call("workspaces.focus", to) end
end)

-- ── volume ──────────────────────────────────────────────────────────
on("vol_step", function(notches) sys.call("audio.step", -0.05 * notches) end)
on("mixer", function() run("pavucontrol", {}, nil, { output = false }) end)

-- ── cpu and memory: no service for these, so /proc, every 5 s (waybar's pace),
-- and only while the card that shows them is open (sampled again as it opens)
local last_total, last_idle = nil, nil
local function sample()
    run("cat", { "/proc/stat", "/proc/meminfo" }, function(out, code)
        if code ~= 0 or not out then return end
        local user, nice, system, idle, iowait, irq, softirq, steal =
            out:match("cpu%s+(%d+)%s+(%d+)%s+(%d+)%s+(%d+)%s+(%d+)%s+(%d+)%s+(%d+)%s+(%d+)")
        if user then
            local idle_all = tonumber(idle) + tonumber(iowait)
            local total = tonumber(user) + tonumber(nice) + tonumber(system) + idle_all
                + tonumber(irq) + tonumber(softirq) + tonumber(steal)
            if last_total and total > last_total then
                fact.cpu = math.floor(100 * (1 - (idle_all - last_idle) / (total - last_total)) + 0.5)
            end
            last_total, last_idle = total, idle_all
        end
        local mt = tonumber(out:match("MemTotal:%s+(%d+)"))
        local ma = tonumber(out:match("MemAvailable:%s+(%d+)"))
        if mt and ma then
            fact.mem = (mt - ma) / 1048576
            fact.mem_frac = (mt - ma) / mt
        end
    end)
end
sample()
every(5000, function() if fact.expanded then sample() end end)
on("fact:expanded", function(e) if e then sample() end end)

-- ── Wi-Fi ───────────────────────────────────────────────────────────
-- The page's rows, in order: the network in use first, then iwd's (strongest
-- first). Each record carries its whole report too, so a row's position is
-- enough to know which network it means.
local nets = {}
local joining = nil        -- the network being joined
local joining_armed = false -- iwd has said "none" since: an error now is this attempt's
local asking = nil         -- the network whose password is asked for
local menu_net = nil       -- the network whose actions are open
local function strength(s) if (s or 0) > 1.5 then return s / 100 end return s or 0 end

local bt_busy = nil        -- the address being connected or left
local bt_was = false       -- whether it was connected when that began
local function spin() fact.busy_any = joining ~= nil or bt_busy ~= nil end

local function show_nets()
    local rows = {}
    for _, n in ipairs(nets) do
        rows[#rows + 1] = {
            ssid = n.ssid, sig = strength(n.strength), secure = n.secure, known = n.known, active = n.active,
            busy = joining == n.ssid, asking = asking == n.ssid, menu = menu_net == n.ssid,
            wrong = asking == n.ssid and fact.pw_bad,
        }
    end
    model.nets = rows
    spin()
end

local function stop_asking()
    asking = nil
    fact.pw_open = false
    fact.pw_bad = false
    text.pass = ""
end

sys.watch("network", function(n)
    fact.wifi_on = n.wifi ~= false
    local list, seen, active = {}, {}, nil
    for _, x in ipairs(n.networks or {}) do
        if x.ssid ~= "" and not seen[x.ssid] then
            seen[x.ssid] = true
            if x.active then active = x else list[#list + 1] = x end
        end
    end
    if active then table.insert(list, 1, active) end
    nets = n.wifi == false and {} or list
    fact.scanning = fact.scanning and n.wifi ~= false

    if joining then
        if active and active.ssid == joining then
            joining = nil
            if asking then stop_asking() end
        elseif n.error == "none" then
            joining_armed = true
        elseif joining_armed then
            local ssid = joining
            joining = nil
            if n.error == "password" then
                asking = ssid
                text.pw_for = ssid
                fact.pw_open = true
                fact.pw_bad = true
                fact.pw_wrongs = fact.pw_wrongs + 1
            end
        end
    end

    if n.wifi == false then text.wifi_label = "Off"
    elseif active then text.wifi_label = active.ssid
    elseif n.kind == "wired" and n.online then text.wifi_label = "Wired"
    else text.wifi_label = "No network" end
    show_nets()
end)

local function join(ssid, password)
    joining = ssid
    joining_armed = false
    menu_net = nil
    local ok = pcall(sys.call, "network.connect", ssid, password)
    if not ok then joining = nil end
    show_nets()
    -- One that never answers stops turning after a while.
    after(25000, function()
        if joining == ssid then joining = nil; show_nets() end
    end)
end

on("wifi_pick", function(i)
    local n = nets[i + 1]
    if not n then return end
    if n.active then
        menu_net = menu_net ~= n.ssid and n.ssid or nil
        show_nets()
    elseif n.known or not n.secure then
        if asking then stop_asking() end
        join(n.ssid)
    else
        menu_net = nil
        asking = n.ssid
        text.pw_for = n.ssid
        fact.pw_bad = false
        fact.pw_open = true
        show_nets()
    end
end)

on("wifi_menu", function(i)
    local n = nets[i + 1]
    if not n or not (n.active or n.known) then return end
    menu_net = menu_net ~= n.ssid and n.ssid or nil
    show_nets()
end)

on("wifi_join", function()
    if not asking or text.pass == "" then return end
    local ssid, password = asking, text.pass
    fact.pw_bad = false
    text.pass = ""
    join(ssid, password)
end)

-- Typing again clears the "wrong" mark.
on("text:pass", function(v) if v ~= "" and fact.pw_bad then fact.pw_bad = false; show_nets() end end)
on("wifi_cancel", function() stop_asking(); show_nets() end)
on("wifi_disconnect", function() menu_net = nil; pcall(sys.call, "network.disconnect"); show_nets() end)
on("wifi_forget", function(i)
    local n = nets[i + 1]
    menu_net = nil
    if n then pcall(sys.call, "network.forget", n.ssid) end
    show_nets()
end)
on("wifi_power", function() pcall(sys.call, "network.wifi", not fact.wifi_on) end)
on("wifi_scan", function()
    if not fact.wifi_on then return end
    pcall(sys.call, "network.scan")
    fact.scanning = true
    -- iwd says nothing when a scan ends: the list arriving is the sign; this is the backstop.
    after(4000, function() fact.scanning = false end)
end)

-- ── Bluetooth ───────────────────────────────────────────────────────
-- My devices (the connected first), then, while the page looks, the named ones nearby.
local devs = {}
local menu_dev = nil
local bt_seen = { powered = false, discovering = false }

local function icon_for(d)
    if d.icon and d.icon ~= "" then return d.icon .. "-symbolic" end
    return "bluetooth-symbolic"
end

local function show_devs()
    local rows = {}
    local mine, near = {}, {}
    for _, d in ipairs(bt_seen.devices or {}) do
        if d.paired or d.connected then mine[#mine + 1] = d
        elseif d.name and d.name ~= "" and d.name ~= d.address then near[#near + 1] = d end
    end
    devs = {}
    for k, d in ipairs(mine) do
        devs[#devs + 1] = d
        local status = d.connected and "Connected" or "Paired"
        if bt_busy == d.address then status = d.connected and "Disconnecting…" or "Connecting…" end
        rows[#rows + 1] = {
            name = d.name, icon = icon_for(d), status = status,
            battery = (d.battery or -1) >= 0 and math.floor(d.battery * 100 + 0.5) or -1,
            connected = d.connected, busy = bt_busy == d.address, menu = menu_dev == d.address,
            caption = k == 1 and 1 or 0,
        }
    end
    for k, d in ipairs(near) do
        devs[#devs + 1] = d
        rows[#rows + 1] = {
            name = d.name, icon = icon_for(d), status = bt_busy == d.address and "Pairing…" or "Not paired",
            battery = -1, connected = false, busy = bt_busy == d.address, menu = false,
            caption = k == 1 and 2 or 0,
        }
    end
    model.devs = rows
    spin()
end

local bt_connected_seen                 -- (below) a device that just connected shows in the pill
sys.watch("bluetooth", function(b)
    if bt_connected_seen then bt_connected_seen(b) end
    bt_seen = b
    if bats_refresh then bats_refresh() end
    fact.bt_on = b.powered == true
    fact.bt_scanning = b.discovering == true
    -- The device being joined or left has got there.
    if bt_busy then
        for _, d in ipairs(b.devices or {}) do
            if d.address == bt_busy and d.connected ~= bt_was then bt_busy = nil end
        end
    end
    local connected = {}
    for _, d in ipairs(b.devices or {}) do
        if d.connected then connected[#connected + 1] = d end
    end
    if not b.present then text.bt_label = "Unavailable"
    elseif not b.powered then text.bt_label = "Off"
    elseif #connected == 1 then
        local d = connected[1]
        text.bt_label = (d.battery or -1) >= 0 and (d.name .. " · " .. math.floor(d.battery * 100 + 0.5) .. "%") or d.name
    elseif #connected > 1 then text.bt_label = #connected .. " connected"
    else
        local paired = false
        for _, d in ipairs(b.devices or {}) do if d.paired then paired = true end end
        text.bt_label = paired and "No device" or "No devices"
    end
    show_devs()
end)

on("bt_pick", function(i)
    local d = devs[i + 1]
    if not d or bt_busy then return end
    bt_busy = d.address
    bt_was = d.connected
    menu_dev = nil
    local ok = pcall(sys.call, d.connected and "bluetooth.disconnect" or "bluetooth.connect", d.address)
    if not ok then bt_busy = nil end
    show_devs()
    after(20000, function()
        if bt_busy == d.address then bt_busy = nil; show_devs() end
    end)
end)
on("bt_menu", function(i)
    local d = devs[i + 1]
    if not d or not (d.paired or d.connected) then return end
    menu_dev = menu_dev ~= d.address and d.address or nil
    show_devs()
end)
on("bt_forget", function(i)
    local d = devs[i + 1]
    menu_dev = nil
    if d then pcall(sys.call, "bluetooth.forget", d.address) end
    show_devs()
end)
on("bt_power", function() pcall(sys.call, "bluetooth.power", not fact.bt_on) end)

-- Nearby devices are only looked for while the page is open: it costs the radio.
local bt_looking = false
local function bt_look(yes)
    if yes == bt_looking then return end
    bt_looking = yes
    pcall(sys.call, "bluetooth.scan", yes)
end
on("fact:panel", function(p) bt_look(p == "bt" and fact.expanded and fact.bt_on) end)
on("fact:expanded", function(e)
    bt_look(e and fact.panel == "bt" and fact.bt_on)
    if not e and (menu_net or menu_dev) then menu_net = nil; menu_dev = nil; show_nets(); show_devs() end
end)

-- ── switching compositor: the bead left of Log out, held ──
-- The other one starts in this same login (dotnix/system/lumen-session),
-- without locking; every window closes and comes back (restore-apps.sh).
on("wm_switch", function()
    run((sys.ask("env", "HOME") or "") .. "/.config/lumen/shells/island/scripts/switch-wm.sh", {}, function(out, code) end)
end)

-- ── session: held buttons on the card ───────────────────────────────
on("log_out", function() pcall(sys.call, "session.logout") end)
on("restart", function() pcall(sys.call, "session.reboot") end)
on("power_off", function() pcall(sys.call, "session.poweroff") end)

-- ── clipboard ───────────────────────────────────────────────────────
-- The whole history stays here; the scene is handed only the five rows in
-- sight (a window over what matches the search), so a long history costs the
-- render nothing and the list never scrolls in the render at all.
local CLIP_ROWS = 8    -- 12 in the taller list beside a large view
-- The texts in full (the service hands over their first 400 characters):
-- read from its history.json when the page opens and after each copy.
local clip_full, clip_dims = {}, {}
local wa_hook = {}         -- WhatsApp's section (at the end) fills it in: what other parts may ask of it
local clip_pv_gen = 0
local clip_preview
local clip_all, clip_hits = {}, {}
local clip_sel, clip_off = 0, 0      -- the chosen one and the first in sight, from 0

local function ago(t)
    local d = os.time() - (t or 0)
    if d < 60 then return "now" end
    if d < 3600 then return math.floor(d / 60) .. "m" end
    if d < 86400 then return math.floor(d / 3600) .. "h" end
    return math.floor(d / 86400) .. "d"
end

local function clip_show()
    local n = #clip_hits
    clip_sel = math.clamp(clip_sel, 0, math.max(0, n - 1))
    -- Keep the chosen one in sight.
    if clip_sel < clip_off then clip_off = clip_sel end
    if clip_sel >= clip_off + CLIP_ROWS then clip_off = clip_sel - CLIP_ROWS + 1 end
    clip_off = math.clamp(clip_off, 0, math.max(0, n - CLIP_ROWS))
    local rows = {}
    for i = clip_off + 1, math.min(clip_off + CLIP_ROWS, n) do
        local c = clip_hits[i]
        rows[#rows + 1] = {
            kind = c.kind == "image" and 1 or 0,
            text = c.flat, thumb = c.thumb or "", ago = ago(c.time), sel = (i - 1) == clip_sel,
            dims = clip_dims[c.id] or "Image",
        }
    end
    model.clips = rows
    fact.clip_total = n
    fact.clip_off = clip_off
    if clip_preview then clip_preview(clip_hits[clip_sel + 1]) end
end

-- The chosen one, large: a text in full, a picture fitted (and its size, once read).
clip_preview = function(c)
    clip_pv_gen += 1
    local gen = clip_pv_gen
    if not c then fact.cpv_kind = 0; return end
    if c.kind == "image" then
        local path = c.image or c.thumb or ""
        run("magick", { "identify", "-format", "%w %h\n", path .. "[0]" }, function(out)
            if gen ~= clip_pv_gen then return end
            local w, h = string.match(out or "", "(%d+) (%d+)")
            w, h = tonumber(w) or 16, tonumber(h) or 9
            local k = math.min(324 / w, 320 / h, 2)
            fact.cpv_iw = math.max(40, math.floor(w * k + 0.5))
            fact.cpv_ih = math.max(30, math.floor(h * k + 0.5))
            text.cpv_img_path = path .. "?" .. gen
            text.cpv_meta = w .. " × " .. h .. " · " .. ago(c.time)
            fact.cpv_kind = 2
            if clip_dims[c.id] ~= w .. " × " .. h then
                clip_dims[c.id] = w .. " × " .. h
            end
        end)
    else
        local full = clip_full[c.id] or c.text or c.flat or ""
        local lines = 1
        for _ in string.gmatch(full, "\n") do lines += 1 end
        text.cpv_text = string.sub(full, 1, 4000)
        text.cpv_meta = utf8.len(full) and (utf8.len(full) .. " characters · " .. lines .. (lines == 1 and " line" or " lines") .. " · " .. ago(c.time)) or ago(c.time)
        fact.cpv_kind = 1
    end
end
on("clip_hover", function(i)
    if i < 0 then clip_preview(clip_hits[clip_sel + 1]) else clip_preview(clip_hits[clip_off + i + 1]) end
end)
-- The clipboard is showing: its own page in the centre card, or beside a large view (the right capsule's card).
local function clip_here() return fact.panel == "clip" or (fact.side and fact.side_k == 1) end
local function clip_load_full()
    run("cat", { (sys.ask("env", "HOME") or "") .. "/.cache/lumen/clipboard/history.json" }, function(out)
        local ok, list = pcall(json.decode, out or "")
        if not ok or type(list) ~= "table" then return end
        for _, x in ipairs(list) do
            if x.id and x.kind == "text" then clip_full[x.id] = x.text end
        end
        if clip_here() then clip_preview(clip_hits[clip_sel + 1]) end
    end)
end

local function clip_filter()
    local q = string.lower(text.clip_q or "")
    fact.clip_q_empty = q == ""
    clip_hits = {}
    for _, c in ipairs(clip_all) do
        if q == "" or string.find(c.low, q, 1, true) then clip_hits[#clip_hits + 1] = c end
    end
    clip_show()
end

-- ── a copy, shown in the pill ──
-- The newest entry changing means something was just copied. Text shows its
-- first line, an image its thumbnail. ocr-sel says beforehand when the next
-- copy is text read off the screen; the colour picker's own copy is left to
-- its own pill.
local clip_top = nil
local ocr_until, pick_until = 0, 0
local function copy_preview(c)
    if os.time() < pick_until then return end
    if c.kind == "image" then
        -- Its real size first, so the card can take the picture's shape.
        local path = c.image or c.thumb or ""
        run("magick", { "identify", "-format", "%w %h\n", path .. "[0]" }, function(out)
            local w, h = string.match(out or "", "(%d+) (%d+)")
            w, h = tonumber(w) or 16, tonumber(h) or 9
            local k = math.min(300 / w, 170 / h, 1.6)
            fact.cp_iw = math.max(40, math.floor(w * k + 0.5))
            fact.cp_ih = math.max(30, math.floor(h * k + 0.5))
            text.cp_dims = w .. " × " .. h
            text.cp_img_path = path
            text.cp_thumb_path = c.thumb or ""
            text.cp_text = "Image"
            fact.cp_kind = 1
            fact.cp_seq = fact.cp_seq + 1
        end)
        return
    else
        local line = ""
        for l in string.gmatch(c.text or c.flat or "", "[^\n]+") do
            l = string.gsub(string.gsub(l, "^%s+", ""), "%s+$", "")
            if l ~= "" then line = l; break end
        end
        text.cp_text = string.gsub(line, "%s+", " ")
        fact.cp_kind = os.time() < ocr_until and 2 or 0
        ocr_until = 0
    end
    fact.cp_seq = fact.cp_seq + 1
end
on("copy_kind", function(k)
    if k == 1 then ocr_until = os.time() + 4
    elseif k == 2 then
        text.cp_text = "No text found"
        fact.cp_kind = 3
        fact.cp_seq = fact.cp_seq + 1
    end
end)

sys.watch("clipboard", function(c)
    clip_all = {}
    for _, x in ipairs(c.list or {}) do
        -- Worked out once per copy, not once per keystroke.
        local flat = x.kind == "image" and "Image" or string.gsub(x.text or "", "%s+", " ")
        clip_all[#clip_all + 1] = { id = x.id, kind = x.kind, thumb = x.thumb, time = x.time, flat = flat, low = string.lower(flat), text = x.text, image = x.image }
    end
    clip_filter()
    if clip_here() then clip_load_full() end
    -- Something new on top (not the history arriving at startup): show it in the pill.
    local top = clip_all[1]
    if top and clip_top ~= nil and top.id ~= clip_top then copy_preview(top) end
    if top then clip_top = top.id end
end)

on("text:clip_q", function() clip_sel, clip_off = 0, 0; clip_filter() end)
local function clip_fresh(rows)
    CLIP_ROWS = rows
    text.clip_q = ""
    clip_sel, clip_off = 0, 0
    clip_filter()
    clip_load_full()
end
on("fact:panel", function(p) if p == "clip" then clip_fresh(8) end end)
on("clip_move", function(d) clip_sel += d; clip_show() end)
on("clip_scroll", function(w)
    -- The wheel moves the window and takes the choice along with it.
    local step = w > 0 and -1 or 1
    clip_off = math.clamp(clip_off + step, 0, math.max(0, #clip_hits - CLIP_ROWS))
    clip_sel = math.clamp(clip_sel, clip_off, clip_off + CLIP_ROWS - 1)
    clip_show()
end)

-- Something chosen in a tool beside a large view goes into it: WhatsApp's field (a picture as a
-- file to send), the mail's reply; elsewhere it is only copied. Then the tool closes, the view stays.
local function side_put(words, picture)
    if fact.panel == "wa" and fact.wa_open then
        if picture then wa_hook.stage(picture) else wa_hook.insert(words) end
        return true
    elseif fact.panel == "mailx" and fact.mr_rep and words then
        text.mr_in = (text.mr_in or "") .. words
        return true
    end
    return false
end
local function clip_take(i)
    local c = clip_hits[i + 1]
    if not c then return end
    pcall(sys.call, "clipboard.pick", c.id)
    if fact.side then
        local words = c.kind ~= "image" and (clip_full[c.id] or c.text) or nil
        side_put(words and string.gsub(words, "[\r\n\t]+", " ") or nil, c.kind == "image" and c.image or nil)
        fact.side = false
        return
    end
    fact.expanded = false
end
on("clip_pick", function() clip_take(clip_sel) end)
on("clip_pick_row", function(i) clip_take(clip_off + i) end)
local function clip_forget(i)
    local c = clip_hits[i + 1]
    if c then pcall(sys.call, "clipboard.remove", c.id) end
end
on("clip_del", function() clip_forget(clip_sel) end)
on("clip_del_row", function(i) clip_forget(clip_off + i) end)
on("clip_clear", function() pcall(sys.call, "clipboard.clear") end)

-- ── launcher ────────────────────────────────────────────────────────
-- Apps by name, ranked the way the eye expects (a name that starts with what
-- was typed, then a word in it that does, then anywhere, then the letters in
-- order) and nudged by how often each was launched. A leading space searches
-- files under home with fd instead; Tab goes into a folder, Shift+Tab out.
-- Like the clipboard, the scene only ever gets the five rows in sight.
local HOME = sys.ask("env", "HOME") or ""
local LAUNCH_ROWS = 5
local apps_all, launch_hits = {}, {}
local launch_sel, launch_off = 0, 0
-- What it learns, kept in the scene's folder: when each app was launched (the
-- last 30 times), which app each typed search ended in, and the files opened.
local store = sys.ask("files.read", "launches.json", "json") or {}
if type(store.apps) ~= "table" then store = { apps = {}, queries = {}, files = {} } end
store.queries = store.queries or {}
store.files = store.files or {}
local function save_store() pcall(sys.call, "files.write", "launches.json", store) end

local DAY = 86400
local function hour_of(t)
    local ok, d = pcall(os.date, "*t", t)
    return ok and d and d.hour or 0
end
-- How much an app is "yours" right now: every launch counts, the recent ones
-- more (a week fades it to a third), and those made near this hour of the day
-- more again, so the morning's apps lead in the morning.
local function frecency(key)
    local times = store.apps[key]
    if not times then return 0 end
    local now, hour, f = os.time(), hour_of(os.time()), 0
    for _, t in ipairs(times) do
        local dh = math.abs(hour_of(t) - hour)
        if dh > 12 then dh = 24 - dh end
        f += math.exp(-(now - t) / (6 * DAY)) * (dh <= 2 and 1.6 or 1)
    end
    return f
end
-- What past searches say about this one: an app picked after typing something
-- that begins the same way as what is typed now.
local function learned(key, q)
    if q == "" then return 0 end
    local n = 0
    for past, picks in pairs(store.queries) do
        if picks[key] and (string.sub(past, 1, #q) == q or string.sub(q, 1, #past) == past) then
            n += picks[key]
        end
    end
    return n
end
local browse = nil          -- the folder being browsed, or nil: search all of home
local file_token = 0        -- the newest file search: older answers are dropped

local function tilde(p)
    if HOME ~= "" and string.sub(p, 1, #HOME) == HOME then return "~" .. string.sub(p, #HOME + 1) end
    return p
end

local function launch_show()
    local n = #launch_hits
    launch_sel = math.clamp(launch_sel, 0, math.max(0, n - 1))
    if launch_sel < launch_off then launch_off = launch_sel end
    if launch_sel >= launch_off + LAUNCH_ROWS then launch_off = launch_sel - LAUNCH_ROWS + 1 end
    launch_off = math.clamp(launch_off, 0, math.max(0, n - LAUNCH_ROWS))
    local rows = {}
    for i = launch_off + 1, math.min(launch_off + LAUNCH_ROWS, n) do
        local h = launch_hits[i]
        rows[#rows + 1] = { kind = h.kind, name = h.name, sub = h.sub or "", has_sub = (h.sub or "") ~= "", icon = h.icon or "", sel = (i - 1) == launch_sel }
    end
    model.hits = rows
    fact.launch_total = n
    fact.launch_off = launch_off
end

-- How well a name answers what was typed: higher is better, 0 is not at all.
local function score(low, q)
    if q == "" then return 1 end
    if string.sub(low, 1, #q) == q then return 100 - #low * 0.1 end
    if string.find(low, "[%s%-_%.]" .. q:gsub("%p", "%%%0")) then return 70 - #low * 0.1 end
    if string.find(low, q, 1, true) then return 50 - #low * 0.1 end
    -- The letters in order, anywhere: "ff" finds Firefox.
    local at = 1
    for k = 1, #q do
        local c = string.sub(q, k, k)
        local f = string.find(low, c, at, true)
        if not f then return 0 end
        at = f + 1
    end
    return 20 - #low * 0.1
end

local function search_apps(q)
    local scored = {}
    if q == "" then
        -- Nothing typed: suggestions, the apps that are most yours right now.
        for _, a in ipairs(apps_all) do
            local f = frecency(a.key)
            if f > 0.05 then scored[#scored + 1] = { a = a, s = f } end
        end
        -- Until it has learned anything, everything, by name.
        if #scored == 0 then
            for _, a in ipairs(apps_all) do scored[#scored + 1] = { a = a, s = 0 } end
        end
    else
        for _, a in ipairs(apps_all) do
            local s = score(a.low, q)
            if s > 0 then
                -- The match decides what shows; what was learned decides the order
                -- among close matches: past picks for searches like this one, then
                -- how much the app is used at all.
                scored[#scored + 1] = { a = a, s = s + math.min(45, 15 * learned(a.key, q)) + math.min(15, 4 * frecency(a.key)) }
            end
        end
    end
    table.sort(scored, function(x, y) if x.s ~= y.s then return x.s > y.s end return x.a.low < y.a.low end)
    launch_hits = {}
    for _, x in ipairs(scored) do
        launch_hits[#launch_hits + 1] = { kind = 0, name = x.a.name, icon = x.a.icon, app = x.a }
    end
    fact.launch_state = #launch_hits == 0 and 1 or 0
    launch_show()
end

local function search_files(q)
    file_token += 1
    -- A bare space: the files and folders opened lately, as suggestions.
    if q == "" and not browse and #store.files > 0 then
        launch_hits = {}
        for _, f in ipairs(store.files) do
            local base = string.match(f.path, "([^/]+)$") or f.path
            launch_hits[#launch_hits + 1] = { kind = f.kind, name = base, sub = tilde(string.match(f.path, "^(.*)/[^/]+$") or ""), path = f.path }
        end
        fact.launch_state = 0
        launch_show()
        return
    end
    local token = file_token
    fact.launch_state = 2
    local dir = browse or HOME
    -- A short pause while typing: one fd for a word, not one per letter.
    after(browse and 0 or 90, function()
        if token ~= file_token then return end
        local args = { "-i", "-F", "--max-results", "80", "-t", "f", "-t", "d" }
        if browse or q == "" then table.insert(args, "--max-depth"); table.insert(args, "1") end
        table.insert(args, q)
        table.insert(args, dir)
        run("fd", args, function(out, code)
            if token ~= file_token then return end
            local found, ql = {}, string.lower(q)
            for line in string.gmatch(out or "", "[^\n]+") do
                local isdir = string.sub(line, -1) == "/"
                local path = isdir and string.sub(line, 1, -2) or line
                local base = string.match(path, "([^/]+)$") or path
                local parent = string.match(path, "^(.*)/[^/]+$") or ""
                local bl = string.lower(base)
                local rank = (ql ~= "" and string.sub(bl, 1, #ql) == ql) and 0 or 1
                -- Inside a folder they all live in it: saying so on every row is noise.
                found[#found + 1] = { kind = isdir and 2 or 1, name = base, sub = browse and "" or tilde(parent), path = path, rank = rank, depth = #path }
            end
            -- What starts with it first, then the nearest; folders before files.
            table.sort(found, function(x, y)
                if x.rank ~= y.rank then return x.rank < y.rank end
                if x.kind ~= y.kind then return x.kind > y.kind end
                return x.depth < y.depth
            end)
            launch_hits = found
            fact.launch_state = #found == 0 and 1 or 0
            launch_show()
        end)
    end)
end

local function launch_refresh()
    local raw = text.launch_q or ""
    fact.launch_q_empty = raw == ""
    local files = string.sub(raw, 1, 1) == " "
    fact.files_mode = files
    if not files then browse = nil end
    text.launch_where = browse and tilde(browse) or "Files"
    if files then
        search_files((string.gsub(string.sub(raw, 2), "^%s+", "")))
    else
        search_apps(string.lower(raw))
    end
end

local app_by_class = {}                -- a window's class → its app (icon, name), for the window viewer
local resolve_icons                    -- (below) WhiteSur-dark's icons for every app
sys.watch("apps", function(list)
    apps_all = {}
    app_by_class = {}
    for _, a in ipairs(list or {}) do
        local info = { name = (a.local_name ~= "" and a.local_name) or a.name, icon = a.icon or "" }
        for _, k in ipairs({ a.wmclass or "", a.id or "", a.name or "" }) do
            if k ~= "" and not app_by_class[string.lower(k)] then app_by_class[string.lower(k)] = info end
        end
    end
    local seen = {}
    for _, a in ipairs(list or {}) do
        local name = a.local_name ~= "" and a.local_name or a.name
        local key = name .. "\0" .. (a.exec or "")
        if name and name ~= "" and not seen[key] then
            seen[key] = true
            apps_all[#apps_all + 1] = { name = name, low = string.lower(name), exec = a.exec, icon = a.icon or "", key = a.id or name }
        end
    end
    table.sort(apps_all, function(x, y) return x.low < y.low end)
    if resolve_icons then resolve_icons(list or {}) end
    if fact.panel == "launch" then launch_refresh() end
end)

on("text:launch_q", function() launch_sel, launch_off = 0, 0; launch_refresh() end)
on("fact:panel", function(p)
    if p == "launch" then
        browse = nil
        text.launch_q = ""
        launch_sel, launch_off = 0, 0
        launch_refresh()
    end
end)
on("launch_move", function(d) launch_sel += d; launch_show() end)
on("launch_scroll", function(w)
    launch_off = math.clamp(launch_off + (w > 0 and -1 or 1), 0, math.max(0, #launch_hits - LAUNCH_ROWS))
    launch_sel = math.clamp(launch_sel, launch_off, launch_off + LAUNCH_ROWS - 1)
    launch_show()
end)

local function launch_take(i)
    local h = launch_hits[i + 1]
    if not h then return end
    if h.kind == 0 then
        if pcall(sys.call, "apps.launch", h.app.exec) then
            local key = h.app.key
            local times = store.apps[key] or {}
            times[#times + 1] = os.time()
            while #times > 30 do table.remove(times, 1) end
            store.apps[key] = times
            -- What was typed, and what it ended in.
            local q = string.lower(text.launch_q or "")
            if q ~= "" and string.sub(q, 1, 1) ~= " " then
                local picks = store.queries[q] or {}
                picks[key] = (picks[key] or 0) + 1
                store.queries[q] = picks
            end
            save_store()
        end
    else
        run("xdg-open", { h.path }, nil, { output = false })
        for k = #store.files, 1, -1 do
            if store.files[k].path == h.path then table.remove(store.files, k) end
        end
        table.insert(store.files, 1, { path = h.path, kind = h.kind })
        while #store.files > 20 do table.remove(store.files) end
        save_store()
    end
    fact.expanded = false
end
on("launch_pick", function() launch_take(launch_sel) end)
on("launch_pick_row", function(i) launch_take(launch_off + i) end)

-- Into the chosen folder, and back out (never above home).
on("launch_into", function()
    local h = launch_hits[launch_sel + 1]
    if not h or h.kind ~= 2 then return end
    browse = h.path
    launch_sel, launch_off = 0, 0
    text.launch_q = " "
    launch_refresh()
end)
on("launch_up", function()
    if not browse then return end
    local parent = string.match(browse, "^(.*)/[^/]+$")
    browse = (parent and #parent >= #HOME and parent ~= HOME) and parent or nil
    launch_sel, launch_off = 0, 0
    text.launch_q = " "
    launch_refresh()
end)

-- ── notifications ───────────────────────────────────────────────────
-- The island is the desktop's notification server. Nothing expires by itself
-- (the list is a centre: what has not been dealt with stays), while the banner
-- the pill grows into goes on its own after a few seconds (the scene times it).
local kept = false

local notes_all = {}
local notes_off = 0
-- Gmail's banners ride the notifications' own (a note with `mail` set); what
-- they do is the mail section's, further down, which fills this in.
local mail_hook = {}
-- WhatsApp's ride them too (a note with `wa` set), through `wa_hook` (declared further up).
local NOTE_ROWS = 4
local seen_id = nil        -- the newest id already known: only newer ones get a banner
local banner_note = nil
local banner_app = ""
local batch = {}           -- the others that arrived while this banner showed

-- Mute, remembered between runs.
local settings = sys.ask("files.read", "settings.json", "json") or {}
fact.dnd = settings.dnd == true
on("dnd_toggle", function()
    settings.dnd = not fact.dnd
    fact.dnd = settings.dnd
    pcall(sys.call, "files.write", "settings.json", settings)
end)

-- What apps send can carry a little markup (<b>, <a href>, &amp;): text only here.
local function plain(s)
    s = string.gsub(s or "", "<[^>]*>", "")
    s = string.gsub(s, "&lt;", "<"); s = string.gsub(s, "&gt;", ">"); s = string.gsub(s, "&quot;", '"')
    s = string.gsub(s, "&apos;", "'"); s = string.gsub(s, "&#39;", "'"); s = string.gsub(s, "&amp;", "&")
    return (string.gsub(s, "^%s+", ""))
end
-- An app's icon by name, from WhiteSur-dark (scripts/icons.sh), remembered;
-- asked for once in the background, so the next notice from it has it.
local ws_icon_cache, ws_icon_asked = {}, {}
local function ws_icon(name)
    if name == "" or string.sub(name, 1, 1) == "/" then return name end
    local hit = ws_icon_cache[name]
    if hit then return hit end
    if not ws_icon_asked[name] then
        ws_icon_asked[name] = true
        run(HOME .. "/.config/lumen/shells/island/scripts/icons.sh", {}, function(out)
            local pth = string.match(out or "", "^([^\n]+)")
            if pth and pth ~= "-" then ws_icon_cache[name] = pth end
        end, { input = name .. "\n" .. string.lower(name) .. "\n" })
    end
    return name
end
local function picture_of(n)
    local img = n.image or ""
    if img ~= "" then return (string.gsub(img, "^file://", "")), true end
    local icon = string.gsub(n.icon or "", "^file://", "")
    -- The app's icon as the rest of the island draws it: WhiteSur-dark.
    local info = app_by_class[string.lower(n.app or "")] or app_by_class[string.lower(icon)]
    if info and string.sub(info.icon or "", 1, 1) == "/" then return info.icon, false end
    if icon == "" then icon = "preferences-system-notifications" end
    return ws_icon(icon), false
end
local function ago_of(t)
    local d = os.time() - (t or os.time())
    if d < 60 then return "now" end
    if d < 3600 then return math.floor(d / 60) .. "m" end
    if d < 86400 then return math.floor(d / 3600) .. "h" end
    return math.floor(d / 86400) .. "d"
end

local function notes_show()
    notes_off = math.clamp(notes_off, 0, math.max(0, #notes_all - NOTE_ROWS))
    local rows = {}
    for i = notes_off + 1, math.min(notes_off + NOTE_ROWS, #notes_all) do
        local n = notes_all[i]
        local pic, is_pic = picture_of(n)
        rows[#rows + 1] = {
            app = n.app ~= "" and n.app or "Notification", title = plain(n.title), body = (string.gsub(plain(n.body), "%s+", " ")),
            pic = pic, is_pic = is_pic, urgent = (n.urgency or 1) >= 2, ago = ago_of(n.time),
        }
    end
    model.notes = rows
    fact.n_count = #notes_all
end

local function show_banner(n)
    banner_note = n
    local pic, is_pic = picture_of(n)
    banner_app = n.app ~= "" and n.app or "Notification"
    text.n_app = banner_app
    text.n_title = plain(n.title) ~= "" and plain(n.title) or plain(n.body)
    text.n_body = plain(n.title) ~= "" and plain(n.body) or ""
    text.n_pic_path = pic
    fact.n_is_pic = is_pic
    fact.n_urgent = (n.urgency or 1) >= 2
    local acts = {}
    for _, a in ipairs(n.actions or {}) do
        if a.key ~= "default" and #acts < 3 then acts[#acts + 1] = { label = a.label, key = a.key } end
    end
    model.nacts = acts
    fact.banner = true
    fact.banner_seq = fact.banner_seq + 1
end

sys.watch("notifications", function(list)
    -- Asked once the service is up (asked before, it is not there yet to hear it).
    if not kept then kept = pcall(sys.call, "notifications.keep", true) end
    notes_all = list or {}
    local newest = notes_all[1]
    if seen_id == nil then
        -- What was already there when the island started is not news.
        seen_id = newest and newest.id or 0
    elseif newest and newest.id > seen_id then
        -- Everything newer than what was known: one banner for all of them,
        -- the newest on it and the rest counted behind it.
        local fresh = {}
        for _, n in ipairs(notes_all) do if n.id > seen_id then fresh[#fresh + 1] = n end end
        seen_id = newest.id
        local urgent = (newest.urgency or 1) >= 2
        if not fact.expanded and (not fact.dnd or urgent) then
            if fact.banner and banner_note then batch[#batch + 1] = banner_note end
            for k = 2, #fresh do batch[#batch + 1] = fresh[k] end
            show_banner(newest)
        end
    end
    -- Of those behind it, the ones still there.
    local alive = {}
    for _, n in ipairs(notes_all) do alive[n.id] = true end
    local kept = {}
    for _, b in ipairs(batch) do if alive[b.id] and (not banner_note or b.id ~= banner_note.id) then kept[#kept + 1] = b end end
    batch = kept
    fact.n_more = fact.banner and #batch or 0
    -- The count rides on the app line: "Discord · 3 more".
    if fact.banner then text.n_app = #batch > 0 and (banner_app .. "  ·  " .. #batch .. " more") or banner_app end
    -- The one on the banner: updated in place if its app replaced it, let go if it closed it.
    if banner_note and not banner_note.mail and not banner_note.wa then
        local still = nil
        for _, n in ipairs(notes_all) do if n.id == banner_note.id then still = n end end
        if not still then
            fact.banner = false
            banner_note = nil
        elseif still.title ~= banner_note.title or still.body ~= banner_note.body then
            show_banner(still)
        end
    end
    notes_show()
end)

local function open_note(n)
    if not n then return end
    -- Its default action if it has one (the app comes forward), then it is dealt with.
    for _, a in ipairs(n.actions or {}) do
        if a.key == "default" then pcall(sys.call, "notifications.invoke", n.id, "default") end
    end
    pcall(sys.call, "notifications.dismiss", n.id)
end
on("note_open", function()
    if banner_note and banner_note.wa then wa_hook.open(banner_note.jid)
    elseif banner_note and banner_note.mail then mail_hook.open(banner_note.uid) else open_note(banner_note) end
    fact.banner = false
end)
-- The banner gone (timed out, flicked away, or the card opened): its batch is
-- only in the list now.
on("fact:banner", function(b) if not b then batch = {}; fact.n_more = 0 end end)
on("note_dismiss", function()
    if banner_note and not banner_note.mail and not banner_note.wa then pcall(sys.call, "notifications.dismiss", banner_note.id) end
    fact.banner = false
end)
on("note_act", function(i)
    local a = model.nacts[i + 1]
    if banner_note and banner_note.wa and a then
        wa_hook.act(banner_note.jid, a.key)
    elseif banner_note and banner_note.mail and a then
        mail_hook.act(banner_note.uid, a.key)
    elseif banner_note and a then
        pcall(sys.call, "notifications.invoke", banner_note.id, a.key)
        pcall(sys.call, "notifications.dismiss", banner_note.id)
    end
    fact.banner = false
end)
on("note_open_row", function(i) open_note(notes_all[notes_off + i + 1]); fact.expanded = false end)
on("note_del_row", function(i)
    local n = notes_all[notes_off + i + 1]
    if n then pcall(sys.call, "notifications.dismiss", n.id) end
end)
on("notes_clear", function() pcall(sys.call, "notifications.clear") end)
on("notes_scroll", function(w) notes_off += (w > 0 and -1 or 1); notes_show() end)
on("fact:panel", function(p) if p == "notes" then notes_off = 0; notes_show() end end)
-- The "5m" on each row, kept true while the page is open.
every(60000, function() if fact.expanded and fact.panel == "notes" then notes_show() end end)

-- ── tray ────────────────────────────────────────────────────────────
-- The apps' status icons; their menu is read and drawn here, a submenu entered
-- in place with a row to come back.
local tray_list, towner, troot, tpath, tshow_real = {}, nil, {}, {}, {}
sys.watch("tray", function(list)
    -- Apps whose tray icon only repeats what the island already does are left out.
    local skip = { vicinae = true, blueman = true, ["blueman-applet"] = true, iwgtk = true, ["nm-applet"] = true, copyq = true }
    tray_list = {}
    for _, t in ipairs(list or {}) do
        local id = string.lower(t.id or "")
        if not skip[id] and not skip[string.lower(t.title or "")] then tray_list[#tray_list + 1] = t end
    end
    local rows = {}
    for i = 1, math.min(4, #tray_list) do
        local t = tray_list[i]
        rows[#rows + 1] = { icon = t.icon or "", title = t.title ~= "" and t.title or (t.id or "") }
    end
    model.trayi = rows
end)
local function tshow(list)
    local rows = #tpath > 0 and { { back = true, label = "Back" } } or {}
    local real = {}
    -- Separators: never two in a row, none at the ends.
    local clean = {}
    for _, it in ipairs(list or {}) do
        if not (it.separator and (#clean == 0 or clean[#clean].separator)) then clean[#clean + 1] = it end
    end
    while #clean > 0 and clean[#clean].separator do table.remove(clean) end
    for _, it in ipairs(clean) do
        if #rows < 10 then
            rows[#rows + 1] = { label = string.gsub(it.label or "", "_", ""), separator = it.separator, enabled = it.enabled ~= false,
                checked = it.checked == nil and -1 or (it.checked and 1 or 0), children = it.children and #it.children or 0 }
            real[#rows] = it
        end
    end
    model.trows = rows
    tshow_real = real
    local h = 0
    for _, r in ipairs(rows) do h += r.separator and 11 or 32 end
    fact.tm_rows_h = h
end
on("tray_activate", function(i)
    local t = tray_list[i + 1]
    if not t then return end
    pcall(sys.call, "tray.activate", t.key)
end)
on("tray_menu", function(i)
    local t = tray_list[i + 1]
    if not t then return end
    if fact.tmenu_open and towner == t then fact.tmenu_open = false; return end
    local ok, menu = pcall(sys.ask, "tray.menu", t.key)
    if not ok or not menu or #menu == 0 then pcall(sys.call, "tray.context", t.key); return end
    towner, troot, tpath = t, menu, {}
    fact.tm_slot = i
    tshow(menu)
    fact.tmenu_open = true
end)
on("tray_choose", function(i)
    local r = model.trows[i + 1]
    if not r then return end
    if r.back then
        table.remove(tpath)
        tshow(#tpath > 0 and tpath[#tpath].children or troot)
        return
    end
    local it = tshow_real[i + 1]
    if not it then return end
    if it.children and #it.children > 0 then
        tpath[#tpath + 1] = it
        tshow(it.children)
    else
        pcall(sys.call, "tray.menu_click", towner.key, it.id)
        fact.tmenu_open = false
    end
end)

-- ── emoji ───────────────────────────────────────────────────────────
-- 1906 emoji (emoji.tsv beside the scene: emoji, category, name, keywords),
-- read once. Nothing typed: the recent ones, then all of them in order; typed:
-- names that start with it, then a word that does, then keywords. Enter types
-- the chosen one into the window that was in front (and copies it).
local EMO_COLS = 8
local EMO_ROWS = 4    -- 7 in the taller card beside a large view
local emo_all, emo_hits = {}, {}
local emo_sel, emo_off = 0, 0          -- the chosen one, and the first row in sight
local emo_recent = (sys.ask("files.read", "emoji.json", "json") or {}).recent or {}

run("cat", { HOME .. "/.config/lumen/shells/island/emoji.tsv" }, function(out)
    for line in string.gmatch(out or "", "[^\n]+") do
        local e, g, name, tags = string.match(line, "^([^\t]+)\t(%d+)\t([^\t]*)\t?(.*)$")
        if e then emo_all[#emo_all + 1] = { e = e, g = tonumber(g), name = name, low = string.lower(name), tags = " " .. string.lower(tags) .. " " } end
    end
end)

local function emo_show()
    local n = #emo_hits
    emo_sel = math.clamp(emo_sel, 0, math.max(0, n - 1))
    local row = math.floor(emo_sel / EMO_COLS)
    if row < emo_off then emo_off = row end
    if row >= emo_off + EMO_ROWS then emo_off = row - EMO_ROWS + 1 end
    emo_off = math.clamp(emo_off, 0, math.max(0, math.ceil(n / EMO_COLS) - EMO_ROWS))
    local cells = {}
    for i = emo_off * EMO_COLS + 1, math.min((emo_off + EMO_ROWS) * EMO_COLS, n) do
        local h = emo_hits[i]
        cells[#cells + 1] = { e = h.e, name = h.name, sel = (i - 1) == emo_sel }
    end
    model.emo = cells
    local cur = emo_hits[emo_sel + 1]
    text.emo_name = cur and cur.name or ""
    -- Which category the first row in sight is in (the recent ones count as -1).
    local first = emo_hits[emo_off * EMO_COLS + 1]
    fact.emo_cat_at = (first and not first.recent) and first.g or -1
end

local function emo_search()
    local q = string.lower(string.gsub(text.emo_q or "", "^%s+", ""))
    fact.emo_q_empty = q == ""
    emo_hits = {}
    if q == "" then
        local by = {}
        for _, x in ipairs(emo_all) do by[x.e] = x end
        for _, e in ipairs(emo_recent) do
            if by[e] then emo_hits[#emo_hits + 1] = { e = e, name = by[e].name, g = by[e].g, recent = true } end
        end
        for _, x in ipairs(emo_all) do emo_hits[#emo_hits + 1] = x end
    else
        local a, b, c = {}, {}, {}
        local pq = q:gsub("%p", "%%%0")
        for _, x in ipairs(emo_all) do
            if string.sub(x.low, 1, #q) == q then a[#a + 1] = x
            elseif string.find(x.low, " " .. pq) then b[#b + 1] = x
            elseif string.find(x.tags, " " .. pq) or string.find(x.low, q, 1, true) then c[#c + 1] = x end
        end
        for _, t in ipairs({ a, b, c }) do for _, x in ipairs(t) do emo_hits[#emo_hits + 1] = x end end
    end
    emo_show()
end

on("text:emo_q", function() emo_sel, emo_off = 0, 0; emo_search() end)
local function emo_fresh(rows)
    EMO_ROWS = rows
    text.emo_q = ""
    emo_sel, emo_off = 0, 0
    emo_search()
end
on("fact:panel", function(p) if p == "emoji" then emo_fresh(4) end end)
-- A tool opening beside a large view: as fresh as its page in the centre card.
local function side_open()
    if not fact.side then return end
    if fact.side_k == 1 then clip_fresh(12) elseif fact.side_k == 2 then emo_fresh(7) end
end
on("fact:side", side_open)
on("fact:side_k", side_open)
on("emo_move", function(d) emo_sel += d; emo_show() end)
on("emo_scroll", function(w)
    emo_off = math.max(0, emo_off + (w > 0 and -1 or 1))
    emo_off = math.min(emo_off, math.max(0, math.ceil(#emo_hits / EMO_COLS) - EMO_ROWS))
    emo_sel = math.clamp(emo_sel, emo_off * EMO_COLS, (emo_off + EMO_ROWS) * EMO_COLS - 1)
    emo_show()
end)
-- A category: the first of it, at the top.
on("emo_cat", function(k)
    for i, h in ipairs(emo_hits) do
        if (k == -1 and h.recent) or (k ~= -1 and not h.recent and h.g == k) then
            emo_sel = i - 1
            emo_off = math.floor((i - 1) / EMO_COLS)
            emo_show()
            return
        end
    end
end)

local function emo_take(i)
    local h = emo_hits[i + 1]
    if not h then return end
    for k = #emo_recent, 1, -1 do if emo_recent[k] == h.e then table.remove(emo_recent, k) end end
    table.insert(emo_recent, 1, h.e)
    while #emo_recent > 16 do table.remove(emo_recent) end
    pcall(sys.call, "files.write", "emoji.json", { recent = emo_recent })
    -- Beside a large view: into its field, or copied.
    if fact.side then
        if not side_put(h.e) then pcall(sys.call, "clipboard.set", h.e) end
        fact.side = false
        return
    end
    pcall(sys.call, "clipboard.set", h.e)
    fact.expanded = false
    -- Typed once the keyboard is back with the window that had it.
    after(180, function() run("wtype", { h.e }, nil, { output = false }) end)
end
on("emo_pick", function() emo_take(emo_sel) end)
on("emo_pick_cell", function(i) emo_take(emo_off * EMO_COLS + i) end)

-- ── volume and brightness gauge (pages/osd.plm) ─────────────────────
-- The services report what they find at login: that is not a change anyone
-- made, so the gauge only starts listening once they have spoken.
after(2500, function() fact.osd_ready = true end)
local function set_bright(v)
    v = math.max(0.01, math.min(1, v))
    fact.bright = v
    pcall(sys.call, "brightness.level", v)
end
sys.watch("brightness", function(b) if b and b.level and not fact.osd_ready then fact.bright = b.level end end)
-- The keyboard's backlight has no service: its script reads and sets it.
local KBD = HOME .. "/.config/custom_scripts/kbd-backlight.sh"
local function set_kbd(v)
    v = math.max(0, math.min(1, v))
    fact.kbd = v
    run(KBD, { "set", tostring(math.floor(v * 100 + 0.5)) }, nil, { output = false })
end
run(KBD, { "get" }, function(out, code)
    local p = code == 0 and out and tonumber(out:match("%d+"))
    if p then fact.kbd = p / 100 end
end)
on("osd_set", function(v)
    if fact.osd_kind == "bright" then set_bright(v)
    elseif fact.osd_kind == "kbd" then set_kbd(v)
    else pcall(sys.call, "audio.volume", v) end
end)
on("kbd_step", function(notches) set_kbd(fact.kbd - 0.1 * notches) end)
on("osd_mute", function() pcall(sys.call, "audio.mute") end)
on("bright_step", function(notches) set_bright(fact.bright - 0.05 * notches) end)

-- ── wallpapers ──────────────────────────────────────────────────
-- The pictures in the wallpapers folder, handed over nine at a time. Each gets
-- a small thumbnail once (cached in the scene's folder, made one after another
-- so a folder of big PNGs never floods the machine). awww puts the chosen one
-- on, growing out from where the island sits; its daemon remembers it.
local WALL_DIR = HOME .. "/github/config/dotnix/wallpapers"
local WALL_COLS, WALL_ROWS = 3, 3
local walls_all = {}                   -- { path, name, thumb }
local wall_sel, wall_off, wall_cur = 0, 0, ""

local function wall_show()
    local n = #walls_all
    wall_sel = math.clamp(wall_sel, 0, math.max(0, n - 1))
    local row = math.floor(wall_sel / WALL_COLS)
    if row < wall_off then wall_off = row end
    if row >= wall_off + WALL_ROWS then wall_off = row - WALL_ROWS + 1 end
    wall_off = math.clamp(wall_off, 0, math.max(0, math.ceil(n / WALL_COLS) - WALL_ROWS))
    local cells = {}
    for i = wall_off * WALL_COLS + 1, math.min((wall_off + WALL_ROWS) * WALL_COLS, n) do
        local w = walls_all[i]
        cells[#cells + 1] = { thumb = w.thumb, name = w.name, sel = (i - 1) == wall_sel, cur = w.path == wall_cur }
    end
    model.walls = cells
    fact.wall_total = n
    local w = walls_all[wall_sel + 1]
    text.wall_name = w and w.name or ""
end

local function wall_thumb_path(name)
    return folder .. "/wall-" .. string.gsub(name, "[^%w%-_%.]", "_") .. ".png"
end

-- Make the thumbnails still missing, one by one, showing each as it lands.
local function wall_thumbs(have)
    local todo = {}
    for _, w in ipairs(walls_all) do
        local t = wall_thumb_path(w.file)
        if have[t] then w.thumb = t else todo[#todo + 1] = { w = w, t = t } end
    end
    wall_show()
    local function step(k)
        local job = todo[k]
        if not job then return end
        run("magick", { job.w.path .. "[0]", "-thumbnail", "336x210^", "-gravity", "center", "-extent", "336x210", job.t }, function(_, code)
            if code == 0 then job.w.thumb = job.t; wall_show() end
            step(k + 1)
        end)
    end
    step(1)
end

local function wall_scan()
    run("fd", { "-t", "f", "-d", "1", "-e", "png", "-e", "jpg", "-e", "jpeg", "-e", "webp", "-e", "gif", "--absolute-path", ".", WALL_DIR }, function(out, code)
        if code ~= 0 or not out then return end
        local list = {}
        for path in string.gmatch(out, "[^\n]+") do
            local name = string.match(path, "([^/]+)$")
            list[#list + 1] = { path = path, name = string.gsub(name, "%.%w+$", ""), file = name, thumb = "" }
        end
        table.sort(list, function(a, b) return string.lower(a.file) < string.lower(b.file) end)
        -- Two files called alike (idk.jpg, idk.png) keep their extension to tell them apart.
        local seen = {}
        for _, w in ipairs(list) do seen[w.name] = (seen[w.name] or 0) + 1 end
        for _, w in ipairs(list) do if seen[w.name] > 1 then w.name = w.file end end
        -- Keep thumbnails already made for the ones still there.
        local old = {}
        for _, w in ipairs(walls_all) do old[w.path] = w.thumb end
        for _, w in ipairs(list) do w.thumb = old[w.path] or "" end
        walls_all = list
        run("fd", { "-t", "f", "-d", "1", "--absolute-path", "^wall-.*\\.png$", folder }, function(o)
            local have = {}
            for t in string.gmatch(o or "", "[^\n]+") do have[t] = true end
            wall_thumbs(have)
        end)
    end)
end

-- What awww has on screen now: the chosen one starts there.
local function wall_query(then_)
    run("awww", { "query" }, function(out)
        local p = out and string.match(out, "image: ([^\n]+)")
        if p then wall_cur = (string.gsub(p, "%s+$", "")) end
        if then_ then then_() end
    end)
end

local wall_link                        -- (below) keeps the lock screen's wallpaper in step

-- The rest of the desktop takes its colours from the wallpaper: theme.plm (this
-- island's palette, which reloads the scene) and niri's rim. A wallpaper pinned
-- in theme/pins.json keeps its preset exactly; any other gets dusk, re-hued.
-- (A global: the chunk is at Luau's 200 locals.)
function wall_theme(path)
    if path and path ~= "" then
        run(HOME .. "/github/config/dotnix/theme/wallpaper-theme.py", { "apply", path }, nil, { output = false })
    end
end

local function wall_set(i)
    local w = walls_all[i + 1]
    if not w then return end
    wall_sel = i
    wall_cur = w.path
    wall_show()
    if wall_link then wall_link(w.path) end
    -- The new one grows out of the island: a circle from the top centre (awww counts y from the bottom).
    run("awww", { "img", w.path, "--transition-type", "grow", "--transition-pos", "0.5,0.985",
        "--transition-duration", "1.1", "--transition-fps", "60", "--transition-bezier", ".3,0,.2,1" }, nil, { output = false })
    -- Halfway through the grow, so the colours turn with the picture.
    after(500, function() wall_theme(w.path) end)
end

wall_scan()
wall_query()

on("fact:panel", function(p)
    if p == "wall" then
        wall_query(function()
            for i, w in ipairs(walls_all) do if w.path == wall_cur then wall_sel = i - 1 end end
            wall_show()
        end)
        wall_scan()
        -- Work out every wallpaper's theme now, so the one picked recolours at once.
        run(HOME .. "/github/config/dotnix/theme/wallpaper-theme.py", { "warm" }, nil, { output = false })
    end
end)
on("wall_move", function(d) wall_sel += d; wall_show() end)
on("wall_scroll", function(wh)
    wall_off = math.max(0, wall_off + (wh > 0 and -1 or 1))
    wall_off = math.min(wall_off, math.max(0, math.ceil(#walls_all / WALL_COLS) - WALL_ROWS))
    wall_sel = math.clamp(wall_sel, wall_off * WALL_COLS, (wall_off + WALL_ROWS) * WALL_COLS - 1)
    wall_show()
end)
on("wall_pick", function() wall_set(wall_sel) end)
on("wall_pick_cell", function(i) wall_set(wall_off * WALL_COLS + i) end)

-- ── the calendar (hovering the date) ────────────────────────────
-- The month as six rows at most, Monday first; the days of the months either
-- side fill the first and last rows, dimmed. Opening it comes back to today.
local MONTHS = { "January", "February", "March", "April", "May", "June", "July",
    "August", "September", "October", "November", "December" }
local cal_y, cal_m

local function cal_show()
    local now = os.date("*t")
    local first = os.time({ year = cal_y, month = cal_m, day = 1, hour = 12 })
    local lead = (tonumber(os.date("%w", first)) + 6) % 7          -- Monday first
    local days = os.date("*t", os.time({ year = cal_y, month = cal_m + 1, day = 0, hour = 12 })).day
    local prev = os.date("*t", os.time({ year = cal_y, month = cal_m, day = 0, hour = 12 })).day
    local weeks = math.ceil((lead + days) / 7)
    local here = now.year == cal_y and now.month == cal_m
    local cells = {}
    for i = 0, weeks * 7 - 1 do
        local d = i - lead + 1
        if d < 1 then
            cells[#cells + 1] = { d = tostring(prev + d), inm = false, today = false }
        elseif d > days then
            cells[#cells + 1] = { d = tostring(d - days), inm = false, today = false }
        else
            cells[#cells + 1] = { d = tostring(d), inm = true, today = here and d == now.day,
                ev = CAL_DAYS[cal_y .. "-" .. cal_m .. "-" .. d] == true }
        end
    end
    model.cdays = cells
    fact.cal_weeks = weeks
    fact.cal_here = here
    text.cal_month = MONTHS[cal_m]
    text.cal_year = tostring(cal_y)
end

-- Days that have something on them (filled in by the Up next code below).
CAL_DAYS = {}
cal_redraw = function() if cal_y then cal_show() end end

on("cal_look", function()
    local now = os.date("*t")
    cal_y, cal_m = now.year, now.month
    cal_show()
end)
-- ±1 a month (the wheel can give more); 0 back to this one.
on("cal_step", function(d)
    if not cal_y then local now = os.date("*t"); cal_y, cal_m = now.year, now.month end
    if d == 0 then
        local now = os.date("*t")
        cal_y, cal_m = now.year, now.month
    else
        local m = cal_m - 1 + (d > 0 and 1 or -1)
        cal_y, cal_m = cal_y + math.floor(m / 12), m % 12 + 1
    end
    cal_show()
end)

-- ── the battery's estimate (hovering the battery) ───────────────
-- Read from sysfs: charge (µAh) and current (µA), or energy (µWh) and power
-- (µW) on batteries that count that way. The current jumps with load, so it
-- is smoothed across looks while the pointer stays.
local BAT = "/sys/class/power_supply/BAT0/"
local bat_rate = nil

local function bat_fmt(hours)
    local mins = math.floor(hours * 60 + 0.5)
    if mins < 60 then return mins .. "m" end
    return math.floor(mins / 60) .. "h " .. (mins % 60) .. "m"
end

local bat_was = nil
local function bat_say(status, now, full, rate)
    -- The charger plugged or unplugged since: start the average afresh.
    if status ~= bat_was then bat_rate = nil; bat_was = status end
    if status == "Full" or (status ~= "Discharging" and now >= full * 0.995) then
        text.bat_tip = "Fully charged"
    elseif status == "Not charging" then
        text.bat_tip = "Not charging"
    elseif not rate or rate <= 0 then
        text.bat_tip = "Estimating…"
    else
        bat_rate = bat_rate and (bat_rate * 0.6 + rate * 0.4) or rate
        if status == "Charging" then
            text.bat_tip = bat_fmt((full - now) / bat_rate) .. " until full"
        else
            text.bat_tip = bat_fmt(now / bat_rate) .. " left"
        end
    end
    fact.bat_has = true
end

local function bat_read(names, fallback)
    local args = { BAT .. "status" }
    for _, n in ipairs(names) do args[#args + 1] = BAT .. n end
    run("cat", args, function(out, code)
        if code ~= 0 or not out then
            if fallback then fallback() end
            return
        end
        local v = {}
        for line in string.gmatch(out, "[^\n]+") do v[#v + 1] = line end
        bat_say(v[1], tonumber(v[2]) or 0, tonumber(v[3]) or 1, math.abs(tonumber(v[4]) or 0))
    end)
end

on("bat_look", function()
    bat_read({ "charge_now", "charge_full", "current_now" }, function()
        bat_read({ "energy_now", "energy_full", "power_now" })
    end)
end)
on("fact:bat_peek", function(v) if not v then bat_rate = nil end end)

-- ── the window switcher ─────────────────────────────────────────
-- The compositor (Hyprland or niri) says which windows there are and in what
-- order they were used (scripts/windows.sh); the thumbnails service has their pictures. They are
-- matched by class and title, and only the six in sight are copied, only
-- while the page is open.
local SCRIPTS = HOME .. "/.config/lumen/shells/island/scripts/"

-- Landing on another desktop, the pill says where: its name (or "Desktop N"),
-- and the icons of its apps, most recently used first.
function wsl.landed(w)
    local name = ""
    for _, d in ipairs(w.list) do
        if d.id == w.active then name = d.name or "" end
    end
    local key = name ~= "" and ("special:" .. name) or tostring(math.floor(w.active))
    run(SCRIPTS .. "windows.sh", {}, function(out)
        local icons, seen = {}, {}
        for line in string.gmatch(out or "", "[^\n]+") do
            local ws, class = string.match(line, "^[^\t]*\t([^\t]*)\t([^\t]*)")
            if ws == key then
                local tail = string.match(class, "([^%.]+)$") or class
                local info = app_by_class[string.lower(class)] or app_by_class[string.lower(tail)]
                local icon = info and info.icon or ""
                if icon ~= "" and not seen[icon] and #icons < 4 then
                    seen[icon] = true
                    icons[#icons + 1] = icon
                end
            end
        end
        for i = 1, 4 do text["ld_a" .. i] = icons[i] or "" end
        fact.ld_n = #icons
        text.ld_name = name ~= "" and (string.upper(string.sub(name, 1, 1)) .. string.sub(name, 2)) or ("Desktop " .. math.floor(w.active))
        fact.ld_seq = fact.ld_seq + 1
    end)
end

local WIN_COLS, WIN_ROWS = 3, 2
local win_all, win_sel, win_off = {}, 0, 0
local win_shots = {}
local win_loaded, win_pending = false, 0

local function win_pic(w, used)
    local best
    for _, t in ipairs(win_shots) do
        if not used[t.id] and string.lower(t.app or "") == string.lower(w.class) then
            if t.title == w.title then best = t; break end
            best = best or t
        end
    end
    if best then used[best.id] = true end
    return best
end

local function win_show()
    local n = #win_all
    win_sel = n > 0 and math.clamp(win_sel, 0, n - 1) or 0
    local row = math.floor(win_sel / WIN_COLS)
    if row < win_off then win_off = row end
    if row >= win_off + WIN_ROWS then win_off = row - WIN_ROWS + 1 end
    win_off = math.clamp(win_off, 0, math.max(0, math.ceil(n / WIN_COLS) - WIN_ROWS))
    local used, cells, want = {}, {}, {}
    for _, w in ipairs(win_all) do w.shot = win_pic(w, used) end
    for i = win_off * WIN_COLS + 1, math.min((win_off + WIN_ROWS) * WIN_COLS, n) do
        local w = win_all[i]
        local pic = w.shot and w.shot.picture or ""
        if w.shot then want[#want + 1] = w.shot.id end
        local ws = string.match(w.ws, "^special:(.*)") and "S" or w.ws
        local tail = string.match(w.class, "([^%.]+)$") or w.class
        local info = app_by_class[string.lower(w.class)] or app_by_class[string.lower(tail)]
        local app = info and info.name or (string.upper(string.sub(tail, 1, 1)) .. string.sub(tail, 2))
        local icon = info and info.icon or ""
        -- A title that only repeats the app's name says where the window is instead.
        local title = w.title
        if string.lower(title) == string.lower(app) or title == "" then
            local sp = string.match(w.ws, "^special:(.*)")
            title = sp and ("Scratchpad · " .. sp) or ("Desktop " .. w.ws)
        end
        cells[#cells + 1] = { picture = pic, icon = icon, has_icon = icon ~= "", title = title, app = app, ws = ws, sel = (i - 1) == win_sel, has_pic = pic ~= "" }
    end
    model.wins = cells
    fact.wins_total = n
    if fact.wv then pcall(sys.call, "thumbnails.want", want) end
end

sys.watch("thumbnails", function(t)
    win_shots = (t and t.list) or {}
    if fact.wv then win_show() end
end)

local function win_step(d)
    local n = #win_all
    if n == 0 then return end
    win_sel = (win_sel + d) % n
    win_show()
end

on("win_look", function(step)
    win_loaded, win_pending = false, 0
    run(SCRIPTS .. "windows.sh", {}, function(out)
        win_all = {}
        for line in string.gmatch(out or "", "[^\n]+") do
            local addr, ws, class, title = string.match(line, "^([^\t]*)\t([^\t]*)\t([^\t]*)\t(.*)$")
            if addr then win_all[#win_all + 1] = { addr = addr, ws = ws, class = class, title = title } end
        end
        win_sel, win_off = 0, 0
        win_loaded = true
        -- Alt+Tab: the one before this one (or, going back, the oldest).
        if step and step ~= 0 then win_step(step) end
        if win_pending ~= 0 then win_step(win_pending) end
        win_show()
    end)
end)
on("win_step", function(d)
    if not win_loaded then win_pending += d; return end
    win_step(d)
end)
local function win_go(i)
    local w = win_all[i + 1]
    if not w then return end
    run(SCRIPTS .. "wm.sh", { "focus", w.addr }, nil, { output = false })
end
on("win_pick", function() win_go(win_sel) end)
on("win_close_cell", function(i)
    local w = win_all[win_off * WIN_COLS + i + 1]
    if not w then return end
    run(SCRIPTS .. "wm.sh", { "close", w.addr }, nil, { output = false })
    -- Its place closes up once the compositor has let it go.
    after(350, function()
        run(SCRIPTS .. "windows.sh", {}, function(out)
            win_all = {}
            for line in string.gmatch(out or "", "[^\n]+") do
                local addr, ws, class, title = string.match(line, "^([^\t]*)\t([^\t]*)\t([^\t]*)\t(.*)$")
                if addr then win_all[#win_all + 1] = { addr = addr, ws = ws, class = class, title = title } end
            end
            win_show()
        end)
    end)
end)
on("win_pick_cell", function(i) win_go(win_off * WIN_COLS + i) end)
on("win_scroll", function(wh)
    win_off = math.max(0, win_off + (wh > 0 and -1 or 1))
    win_off = math.min(win_off, math.max(0, math.ceil(#win_all / WIN_COLS) - WIN_ROWS))
    win_sel = math.clamp(win_sel, win_off * WIN_COLS, (win_off + WIN_ROWS) * WIN_COLS - 1)
    win_show()
end)
on("fact:wv", function(v) if not v then pcall(sys.call, "thumbnails.want") end end)

-- ── capture: screenshots (hypr/scripts/screenshot.sh) and recordings ──
local SHOT = HOME .. "/.config/hypr/scripts/screenshot.sh"
local rec_id, rec_start = nil, 0
local TARGETS = { [0] = "area", [1] = "window", [2] = "screen" }
local REC_TARGETS = { [0] = "region", [1] = "window", [2] = "screen" }

local function rec_tick()
    if not fact.recording then return end
    local s = os.time() - rec_start
    text.rec_time = string.format("%d:%02d", math.floor(s / 60), s % 60)
    after(1000, rec_tick)
end

on("cap_take", function(which)
    -- After the card has gone, so it is not in the picture.
    after(380, function()
        if not fact.cap_rec then
            run(SHOT, { TARGETS[which] or "area", fact.cap_save and "save" or "copy" }, nil, { output = false })
        elseif not rec_id then
            rec_id = spawn(SCRIPTS .. "record.sh", { REC_TARGETS[which] or "screen" }, function(line)
                if line == "started" then
                    rec_start = os.time()
                    text.rec_time = "0:00"
                    fact.recording = true
                    after(1000, rec_tick)
                end
            end, function()
                rec_id = nil
                fact.recording = false
            end)
        end
    end)
end)
on("rec_stop", function() if rec_id then kill(rec_id, "int") end end)

-- ── the mixer ───────────────────────────────────────────────────
local mix_outs, mix_apps = {}, {}
local mix_off = 0                      -- the first app in sight (three show; the wheel scrolls)
local audio_now = nil

local function short_name(n)
    n = string.gsub(n or "", "^Built%-in Audio ", "")
    n = string.gsub(n, " Analog Stereo$", "")
    n = string.gsub(n, "^Analog Stereo$", "Speakers")
    return n ~= "" and n or "Speakers"
end

local function mix_show()
    local a = audio_now
    if not a then return end
    mix_outs, mix_apps = {}, {}
    for _, o in ipairs(a.outputs or {}) do
        if #mix_outs < 3 or o.default then
            if #mix_outs >= 3 then table.remove(mix_outs) end
            mix_outs[#mix_outs + 1] = o
        end
    end
    local rows = {}
    for _, o in ipairs(mix_outs) do rows[#rows + 1] = { name = short_name(o.name), on = o.default and true or false } end
    model.outs = rows
    local apps, all = {}, a.apps or {}
    mix_off = math.clamp(mix_off, 0, math.max(0, #all - 3))
    for i = mix_off + 1, math.min(mix_off + 3, #all) do
        local x = all[i]
        mix_apps[#mix_apps + 1] = x
        -- Its icon as the rest of the island draws it (WhiteSur-dark).
        local info = app_by_class[string.lower(x.binary or "")] or app_by_class[string.lower(x.name or "")]
        local icon = (info and string.sub(info.icon or "", 1, 1) == "/" and info.icon) or ws_icon(x.icon or "")
        apps[#apps + 1] = { name = x.name or "", title = x.title or "", volume = x.volume or 0, muted = x.muted and true or false, icon = icon }
    end
    model.mixapps = apps
    fact.mix_more = math.max(0, #all - 3)
end

sys.watch("audio", function(a)
    audio_now = a
    if fact.panel == "mix" then mix_show() end
end)
on("fact:panel", function(p) if p == "mix" then mix_show() end end)
on("mix_out", function(i) local o = mix_outs[i + 1]; if o then pcall(sys.call, "audio.default", o.id) end end)
on("mix_set", function(code)
    local x = mix_apps[math.floor(code / 1000) + 1]
    if x then pcall(sys.call, "audio.app_volume", x.id, (code % 1000) / 100) end
end)
on("mix_mute", function(i) local x = mix_apps[i + 1]; if x then pcall(sys.call, "audio.app_mute", x.id, not x.muted) end end)
on("mix_master", function(v) pcall(sys.call, "audio.volume", v) end)
on("mix_scroll", function(w) mix_off += (w > 0 and -1 or 1); mix_show() end)

-- ── the colour picker ───────────────────────────────────────────
on("pick_color", function()
    pick_until = os.time() + 120     -- until hyprpicker answers (cleared below)
    after(320, function()
        run("hyprpicker", { "-a", "-f", "hex" }, function(out, code)
            local hex = code == 0 and out and string.match(out, "#%x%x%x%x%x%x")
            if not hex then return end
            text.pk_hex = string.upper(hex)
            fact.pk_r = tonumber(string.sub(hex, 2, 3), 16) / 255
            fact.pk_g = tonumber(string.sub(hex, 4, 5), 16) / 255
            fact.pk_b = tonumber(string.sub(hex, 6, 7), 16) / 255
            fact.pk_seq = fact.pk_seq + 1
            pick_until = os.time() + 2
        end)
    end)
end)

-- ── toggles: night light, keep awake, power mode ────────────────
local night_id, awake_id = nil, nil
on("night_toggle", function()
    if night_id then kill(night_id); night_id = nil; fact.night = false; return end
    -- hyprsunset speaks Hyprland's own protocol; elsewhere (niri) wlsunset, held at 4500 K.
    local night = sys.ask("env", "HYPRLAND_INSTANCE_SIGNATURE") and { "hyprsunset", { "-t", "4500" } } or { "wlsunset", { "-t", "4500", "-T", "4501" } }
    night_id = spawn(night[1], night[2], function() end, function() night_id = nil; fact.night = false end)
    fact.night = true
end)
-- Keep Awake: an inhibitor held by `sleep`, for as long as was chosen (or
-- until turned off); the button counts down what is left, a minute at a time.
local awake_until, awake_gen = 0, 0
local function awake_stop()
    awake_gen += 1
    if awake_id then kill(awake_id); awake_id = nil end
    fact.awake = false
end
local function awake_tick(gen)
    if gen ~= awake_gen or not fact.awake then return end
    if awake_until == 0 then text.awake_left = "On"; return end
    local left = awake_until - os.time()
    if left <= 0 then awake_stop(); return end
    local m = math.ceil(left / 60)
    text.awake_left = (m >= 60) and string.format("%d:%02d left", m // 60, m % 60) or (m .. " min left")
    after(math.min(30000, (left % 60 + 1) * 1000), function() awake_tick(gen) end)
end
on("awake_toggle", function() awake_stop() end)
local function awake_start(mins)
    awake_stop()
    local secs = (mins or 0) * 60
    awake_until = secs > 0 and (os.time() + secs) or 0
    local gen = awake_gen
    -- Its end (the time ran out) ends this run only, never a newer one.
    awake_id = spawn("systemd-inhibit", { "--what=idle:sleep", "--who=Island", "--why=Keep awake", "--mode=block", "sleep", secs > 0 and tostring(secs) or "infinity" },
        function() end, function() if gen == awake_gen then awake_id = nil; awake_stop() end end)
    fact.awake = true
    awake_tick(gen)
end
on("awake_for", awake_start)
local PROFILE_IN = { ["power-saver"] = "saver", balanced = "balanced", performance = "performance" }
local PROFILE_NEXT = { balanced = "performance", performance = "power-saver", saver = "balanced" }
local function profile_read()
    run("powerprofilesctl", { "get" }, function(out)
        local p = PROFILE_IN[string.match(out or "", "[%w%-]+") or ""]
        if p then fact.profile = p end
    end)
end
profile_read()
on("profile_next", function()
    local to = PROFILE_NEXT[fact.profile] or "balanced"
    run("powerprofilesctl", { "set", to }, function() profile_read() end)
end)
on("fact:expanded", function(v) if v then profile_read() end end)

-- ── privacy: who is listening or watching, every 3 s ────────────
every(3000, function()
    run(SCRIPTS .. "privacy.sh", {}, function(out)
        local m, c, s = string.match(out or "", "(%d) (%d) (%d)")
        if not m then return end
        fact.mic_on, fact.cam_on, fact.scr_on = m == "1", c == "1", s == "1"
    end)
end)

-- ── polkit: carry the answer to polkit's helper ─────────────────
on("pk_send", function() pcall(sys.call, "polkit.answer", text.answer); text.answer = "" end)
on("pk_cancel", function() pcall(sys.call, "polkit.cancel"); text.answer = "" end)

-- ── the focused app, right of the workspaces ────────────────────
-- Its icon (and name, for the hover) from the apps service, matched by the
-- window's class. Without an app entry, nothing shows (as waybar).
local front_class = nil
local function front_show()
    local tail = front_class and (string.match(front_class, "([^%.]+)$") or front_class) or ""
    local info = front_class and (app_by_class[string.lower(front_class)] or app_by_class[string.lower(tail)])
    local path = info and info.icon or ""
    -- A new icon goes into the hidden slot, then the scene crossfades to it.
    local shown = fact.front_on_b and text.front_b or text.front_a
    if path ~= shown and path ~= "" then
        if fact.front_on_b then text.front_a = path else text.front_b = path end
        fact.front_on_b = not fact.front_on_b
    end
    text.front_name = info and info.name or ""
    fact.front_has = path ~= ""
end
sys.watch("window", function(w)
    front_class = (w and w.class ~= "" and w.class) or nil
    front_show()
    -- The apps service may not have spoken yet at startup.
    if front_class and not fact.front_has then after(1500, front_show) end
end)

-- ── icons: WhiteSur-dark, as waybar drew them ───────────────────
-- lumen's own lookup tries a fixed list of themes; the icons here are the
-- user's pack instead. For each app: its Icon= name, then its class, id and
-- name in lower case (WhiteSur has `claude`, not `claude-desktop`). The
-- first one the theme has wins; without any, the app keeps its own icon.
resolve_icons = function(list)
    local cands, lines = {}, {}
    for _, a in ipairs(list) do
        local tail = function(x) return string.lower(string.match(x or "", "([^%.]+)$") or "") end
        local c = { a.icon or "", string.lower(a.wmclass or ""), tail(a.id), string.lower(a.id or ""), string.lower(a.name or "") }
        cands[#cands + 1] = c
        for _, n in ipairs(c) do lines[#lines + 1] = n end
    end
    run(SCRIPTS .. "icons.sh", {}, function(out)
        local paths = {}
        for l in string.gmatch(out or "", "[^\n]*\n") do paths[#paths + 1] = string.sub(l, 1, -2) end
        local k, by_icon = 0, {}
        for i, c in ipairs(cands) do
            local found
            for _, _n in ipairs(c) do
                k += 1
                if not found and paths[k] and paths[k] ~= "-" then found = paths[k] end
            end
            local a = list[i]
            if found then
                by_icon[a.icon or ""] = found
                local info = { name = (a.local_name ~= "" and a.local_name) or a.name, icon = found }
                for _, key in ipairs({ a.wmclass or "", a.id or "", a.name or "" }) do
                    if key ~= "" then app_by_class[string.lower(key)] = info end
                end
            end
        end
        for _, x in ipairs(apps_all) do
            if by_icon[x.icon] then x.icon = by_icon[x.icon] end
        end
        front_show()
        if fact.wv then win_show() end
        if fact.panel == "launch" then launch_refresh() end
    end, { input = table.concat(lines, "\n") .. "\n" })
end
do
    local ok, list = pcall(sys.ask, "apps")
    if ok and type(list) == "table" then resolve_icons(list) end
end

-- ── low battery: once at 20 %, once at 10 %, while on battery ───
local low_warned = 0                   -- the lowest threshold already said
sys.watch("battery", function(b)
    if not b or not b.present then return end
    if b.charging then low_warned = 0; return end
    local p = b.percent or 100
    for _, t in ipairs({ 10, 20 }) do
        if p <= t and (low_warned == 0 or t < low_warned) then
            low_warned = t
            text.cp_text = "Low Battery"
            text.cp_dims = math.floor(p + 0.5) .. "%"
            fact.cp_kind = 4
            fact.cp_seq = fact.cp_seq + 1
            fact.low_seq = fact.low_seq + 1
            break
        end
    end
end)

-- ── the lock screen follows the wallpaper ───────────────────────
-- hyprlock reads ~/.cache/lumen/wallpaper, a link kept pointing at what awww shows.
local WALL_LINK = HOME .. "/.cache/lumen/wallpaper"
wall_link = function(path)
    if path and path ~= "" then run("ln", { "-sfn", path, WALL_LINK }, nil, { output = false }) end
end
after(1500, function() wall_link(wall_cur); wall_theme(wall_cur) end)

-- ── a device connects: shown in the pill, with its battery ──────
-- Only a connection made while the island runs (not the ones already there
-- at startup). Its battery often comes a moment after it connects: while it
-- shows, the pill takes it when it arrives.
local bt_known, bt_first, dv_addr = {}, true, nil
local function dv_glyph_of(icon)
    icon = icon or ""
    if string.find(icon, "^audio") then return 0 end
    if string.find(icon, "mouse") or string.find(icon, "tablet") then return 1 end
    if string.find(icon, "keyboard") then return 2 end
    if string.find(icon, "phone") then return 3 end
    return 4
end
bt_connected_seen = function(b)
    local now = {}
    for _, d in ipairs(b.devices or {}) do
        if d.connected then
            now[d.address] = true
            if not bt_first and not bt_known[d.address] then
                dv_addr = d.address
                text.dv_name = d.name or "Device"
                fact.dv_glyph = dv_glyph_of(d.icon)
                fact.dv_bat = d.battery or -1
                fact.dv_seq = fact.dv_seq + 1
            elseif fact.dev_on and d.address == dv_addr and (d.battery or -1) >= 0 then
                fact.dv_bat = d.battery
            end
        end
    end
    bt_known, bt_first = now, false
end

-- ── the timer and the stopwatch ────────────────────────────────
-- Seconds from os.time(); one step a second while running (none at rest).
-- A timer that runs out chimes and says so in the pill.
local CHIME = "/usr/share/sounds/freedesktop/stereo/alarm-clock-elapsed.oga"
local tm = { gen = 0, total = 0, ends = 0, left = 0, started = 0, elapsed = 0 }

local function tm_fmt(sec)
    sec = math.max(0, math.floor(sec + 0.5))
    local h, m, x = math.floor(sec / 3600), math.floor(sec % 3600 / 60), sec % 60
    if h > 0 then return string.format("%d:%02d:%02d", h, m, x) end
    return string.format("%d:%02d", m, x)
end
local function tm_label(sec)
    if sec % 3600 == 0 then local h = sec / 3600; return h == 1 and "1 hour" or (h .. " hours") end
    if sec % 60 == 0 then return (sec / 60) .. " min" end
    return tm_fmt(sec)
end

local function tm_draw()
    if fact.tmr_mode == "timer" then
        local left = fact.tmr_paused and tm.left or (tm.ends - os.time())
        text.tmr_text = tm_fmt(left)
        fact.tmr_frac = tm.total > 0 and math.clamp(left / tm.total, 0, 1) or 0
        return left
    else
        local el = tm.elapsed + (fact.tmr_paused and 0 or (os.time() - tm.started))
        text.tmr_text = tm_fmt(el)
        fact.tmr_frac = 1
        return 1
    end
end

local function tm_done()
    fact.tmr_on = false
    tm.gen += 1
    run("pw-play", { CHIME }, function() run("pw-play", { CHIME }, nil, { output = false }) end, { output = false })
    text.cp_text = "Timer done"
    text.cp_dims = tm_label(tm.total)
    fact.cp_kind = 5
    fact.cp_seq = fact.cp_seq + 1
end

local function tm_tick(gen)
    if gen ~= tm.gen or not fact.tmr_on then return end
    if not fact.tmr_paused then
        local left = tm_draw()
        if fact.tmr_mode == "timer" and left <= 0 then tm_done(); return end
    end
    after(1000, function() tm_tick(gen) end)
end

local function tm_begin()
    tm.gen += 1
    fact.tmr_paused = false
    fact.tmr_on = true
    tm_draw()
    local gen = tm.gen
    after(1000, function() tm_tick(gen) end)
end

local function tm_start_secs(secs)
    fact.tmr_mode = "timer"
    tm.total, tm.ends = secs, os.time() + secs
    text.tmr_total = "of " .. tm_label(secs)
    tm_begin()
end
on("tmr_start", tm_start_secs)
on("watch_start", function()
    fact.tmr_mode = "watch"
    tm.elapsed, tm.started = 0, os.time()
    text.tmr_total = "Stopwatch"
    tm_begin()
end)
on("tmr_pause", function()
    if not fact.tmr_on then return end
    if fact.tmr_paused then
        if fact.tmr_mode == "timer" then tm.ends = os.time() + tm.left else tm.started = os.time() end
        fact.tmr_paused = false
    else
        if fact.tmr_mode == "timer" then tm.left = tm.ends - os.time() else tm.elapsed = tm.elapsed + os.time() - tm.started end
        fact.tmr_paused = true
    end
    tm_draw()
end)
on("tmr_cancel", function() tm.gen += 1; fact.tmr_on = false; fact.tmr_paused = false end)
on("tmr_add", function(secs)
    if fact.tmr_mode ~= "timer" or not fact.tmr_on then return end
    tm.total = tm.total + secs
    if fact.tmr_paused then tm.left = tm.left + secs else tm.ends = tm.ends + secs end
    text.tmr_total = "of " .. tm_label(tm.total)
    tm_draw()
end)

-- ── searches that appear on / (clipboard, emoji) ───────────────
-- Esc in normal mode lets a kept filter go first; the field folds away.
on("clip_q_clear", function() text.clip_q = ""; clip_sel, clip_off = 0, 0; clip_filter() end)
on("emo_q_clear", function() text.emo_q = ""; emo_sel, emo_off = 0, 0; emo_search() end)
-- [ ] : to the first emoji of the category before or after the one in sight.
local EMO_CAT_ORDER = { -1, 0, 1, 3, 4, 5, 6, 7, 8 }
on("emo_cat_step", function(d)
    local at = 1
    for i, k in ipairs(EMO_CAT_ORDER) do if k == fact.emo_cat_at then at = i end end
    local want = EMO_CAT_ORDER[math.clamp(at + d, 1, #EMO_CAT_ORDER)]
    if want == -1 then emo_sel, emo_off = 0, 0; emo_show(); return end
    for i, h in ipairs(emo_hits) do
        if not h.recent and h.g == want then
            emo_sel = i - 1
            emo_off = math.floor((i - 1) / EMO_COLS)
            emo_show()
            return
        end
    end
end)

-- ── the camera ──────────────────────────────────────────────────
-- It runs only while its page shows: started on the way in, let go on the way
-- out (a video being made ends with it). Photos and videos go to
-- ~/Pictures/Camera, named by when they were taken.
local CAM_DIR = HOME .. "/Pictures/Camera"
local SHUTTER = "/usr/share/sounds/freedesktop/stereo/camera-shutter.oga"
local cam_running, cam_rec_gen, cam_rec_from = false, 0, 0

local function cam_stop()
    if cam_running then
        cam_running = false
        cam_rec_gen += 1
        pcall(sys.call, "camera.stop")
    end
end
on("fact:panel", function(p)
    if p == "cam" then
        if not cam_running then cam_running = true; pcall(sys.call, "camera.start") end
    else
        cam_stop()
    end
end)
on("fact:expanded", function(v) if not v then cam_stop() end end)

local function cam_name(kind, ext)
    return CAM_DIR .. "/" .. kind .. " " .. os.date("%Y-%m-%d at %H.%M.%S") .. "." .. ext
end
on("cam_photo", function()
    local path = cam_name("Photo", "jpg")
    local ok = pcall(sys.call, "camera.photo", path)
    if not ok then return end
    run("pw-play", { SHUTTER }, nil, { output = false })
    text.cam_last_photo = path
    fact.cam_has_last = true
    fact.cam_shots = fact.cam_shots + 1
end)
local function cam_tick(gen)
    if gen ~= cam_rec_gen then return end
    local s = os.time() - cam_rec_from
    text.cam_rec_time = string.format("%d:%02d", math.floor(s / 60), s % 60)
    after(1000, function() cam_tick(gen) end)
end
on("cam_record", function()
    local ok, err = pcall(sys.call, "camera.record", cam_name("Video", "mp4"))
    if not ok then log("camera.record failed:", err) end
    if ok then
        cam_rec_gen += 1
        cam_rec_from = os.time()
        text.cam_rec_time = "0:00"
        local gen = cam_rec_gen
        after(1000, function() cam_tick(gen) end)
    end
end)
on("cam_record_stop", function() cam_rec_gen += 1; pcall(sys.call, "camera.record_stop") end)
on("cam_open_last", function()
    if text.cam_last_photo ~= "" then run("xdg-open", { text.cam_last_photo }, nil, { output = false }) end
end)
on("cam_open_dir", function() run("xdg-open", { CAM_DIR }, nil, { output = false }) end)

-- (In a function of its own: one function has room for 200 locals, and the file
-- around it has nearly used them up.)
;(function()
-- ── files: a quick finder (Super+R) ─────────────────────────────
-- Everything under the chosen folders (as fd lists it: .gitignore'd build
-- output and hidden files left out), indexed each time the page opens (5k
-- entries take ~20 ms). Ranked by frecency, as zoxide ranks: how many times
-- each was opened, weighted by how lately; zoxide's own history seeds the
-- folders. An empty search shows the frecent ones; Enter on a folder steps
-- into it (h goes back up), on a file opens it: text and code in Neovim, the
-- rest in its default app (a PDF in zathura).
local FIND_ROOTS = { "github", "Documents", "Downloads", "Pictures", "Videos" }
local FIND_ROWS = 10        -- (12 inside a folder, where rows are a single line: `fnd_show`)
local TEXT_EXT = {}
for e in string.gmatch("txt md markdown rst org log csv tsv json jsonc yaml yml toml ini conf cfg nix lua luau plm py rs go c h cpp hpp cc js ts tsx jsx mjs css scss html xml sh bash zsh fish vim sql tex bib java kt swift rb php r m wgsl glsl svelte vue gitignore env lock", "%S+") do TEXT_EXT[e] = true end
local IMG_EXT = { png = true, jpg = true, jpeg = true, gif = true, webp = true, bmp = true, svg = true, avif = true }
local VID_EXT = { mp4 = true, mkv = true, webm = true, mov = true, avi = true, m4v = true }
local function set_of(list) local t = {} for e in string.gmatch(list, "%S+") do t[e] = true end return t end
-- Documents LibreOffice opens; their text comes out of their XML at once, their first page as a picture after.
local OFFICE_EXT = set_of("docx doc odt rtf pptx ppt odp xlsx xls ods")
local OFFICE_XML = { docx = "word/document.xml", pptx = "ppt/slides/slide1.xml", xlsx = "xl/sharedStrings.xml", odt = "content.xml", odp = "content.xml", ods = "content.xml" }
local ARC_EXT = set_of("zip tar gz tgz xz txz zst bz2 tbz2 7z rar jar apk deb rpm whl epub cbz")
local AUD_EXT = set_of("mp3 flac ogg opus m4a wav aac wma alac aiff")
local FONT_EXT = set_of("ttf otf woff woff2")

local fnd_all, fnd_by_path = {}, {}
local fnd_hits, fnd_sel, fnd_off = {}, 0, 0
local fnd_scope = nil                  -- the folder stepped into, or none
-- Inside a folder, what is in it, read as Thunar shows it (with sizes and
-- times, hidden files only on `.`), sorted by name, modified, size or type.
local fnd_children = {}
local fnd_hidden_on = false
local SORTS = { "name", "modified", "size", "type" }
local SORT_LABEL = { name = "Name", modified = "Modified", size = "Size", type = "Type" }
local fnd_sort_i, fnd_sort_rev = 1, false
-- Marked (Space), and what yy / dd last took: { mode = "copy" | "cut", paths, set }.
local fnd_marked, fnd_nmarks = {}, 0
local fnd_reg = nil
local fnd_prompt_kind, fnd_prompt_for = nil, nil
local fmt_meta                         -- (below) a row's size and age, inside a folder
local fmt_parts                        -- (below) the same, apart: its age, and its size (none for a folder)
local fnd_zox = {}
local fnd_store = (sys.ask("files.read", "finder.json", "json") or {})
fnd_store.hits = fnd_store.hits or {}
local fnd_pv_gen, fnd_pv_slot = 0, 0
-- Reopened within this many seconds, the finder is where it was left: the
-- folder, the search, the cursor. Later, it starts fresh.
local FIND_RESUME = 5 * 60
-- The folders walked through (false = the whole list), for H and L.
local fnd_back, fnd_fwd = {}, {}
-- Per folder ("" = the whole list), the path the cursor was last on.
local fnd_cursor = {}
local fnd_is_open = false
fact.pvd_list = fnd_store.pv_view == "list"
local help_on = false

local function ext_of(path) return string.lower(string.match(path, "%.([%w]+)$") or "") end
local function kind_of(e)
    if e.dir then return 1 end
    local x = ext_of(e.path)
    if IMG_EXT[x] then return 2 end
    if x == "pdf" then return 3 end
    if VID_EXT[x] then return 4 end
    if TEXT_EXT[x] then return 5 end
    return 0
end
local function tilde(p) return (string.gsub(p, "^" .. string.gsub(HOME, "%p", "%%%0"), "~")) end

-- Each entry's icon, as Finder shows it: WhiteSur-dark's (the island's own
-- theme) folder, special folder or type of file, chosen by name and extension
-- among the icons the theme really has (read once).
local ficon = { mimes = {}, places = {}, MIMES = "/usr/share/icons/WhiteSur-dark/mimes/scalable/", PLACES = "/usr/share/icons/WhiteSur-dark/places/scalable/",
    folder = { downloads = "folder-download", documents = "folder-documents", pictures = "folder-pictures", videos = "folder-videos",
        music = "folder-music", desktop = "user-desktop", github = "folder-github", [".git"] = "folder-git", projects = "folder-projects",
        templates = "folder-templates", public = "folder-publicshare", code = "folder-code", src = "folder-code", scripts = "folder-script",
        custom_scripts = "folder-script", games = "folder-games" },
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
        ini = "text-x-generic", conf = "text-x-generic", cfg = "text-x-generic", plm = "text-x-generic" } }
run("find", { ficon.MIMES, ficon.PLACES, "-maxdepth", "1", "-name", "*.svg" }, function(out)
    for path in string.gmatch(out or "", "[^\n]+") do
        local dir, name = string.match(path, "^(.*/)([^/]+)%.svg$")
        if dir == ficon.MIMES then ficon.mimes[name] = true elseif dir == ficon.PLACES then ficon.places[name] = true end
    end
end)
function ficon.of(name, isdir, path)
    if isdir then
        local special = ficon.folder[string.lower(name)]
        return ficon.PLACES .. ((special and ficon.places[special]) and special or "folder") .. ".svg"
    end
    local x = ext_of(path or name)
    local kind = kind_of({ dir = false, path = path or name })
    local generic = ({ [2] = "image-x-generic", [3] = "application-pdf", [4] = "video-x-generic", [5] = "text-x-generic" })[kind]
        or (AUD_EXT[x] and "audio-x-generic") or (ARC_EXT[x] and "package-x-generic") or "text-x-generic"
    for _, n in ipairs({ ficon.ext[x] or "", "image-" .. x, "video-" .. x, "audio-" .. x, "application-x-" .. x, "text-x-" .. x, generic }) do
        if n ~= "" and ficon.mimes[n] then return ficon.MIMES .. n .. ".svg" end
    end
    return ficon.MIMES .. "text-x-generic.svg"
end

local function frecency(path)
    local h = fnd_store.hits[path]
    local f = 0
    if h then
        local age = os.time() - (h.t or 0)
        local w = age < 3600 and 4 or age < 86400 and 2 or age < 604800 and 1 or 0.5
        f = (h.n or 0) * w
    end
    return f + (fnd_zox[path] or 0) / 10
end

-- How well one word matches an entry: in its name first, then anywhere in
-- its path, then as letters in order in its name (fuzzy). Spaces, `_`, `-`
-- and `.` are all alike: "boarding pass" finds boarding_pass.pdf.
local function norm(x) return (string.gsub(x, "[%s_%-%.]+", " ")) end
local function word_score(e, w)
    local a = string.find(e.n_name, w, 1, true)
    if a then return (a == 1 and 140 or 110) - #e.n_name * 0.2 end
    if string.find(e.n_path, w, 1, true) then return 60 - #e.n_path * 0.03 end
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
-- Every word of the search has to match; their scores add up.
local function fuzzy(e, q)
    local total = 0
    for w in string.gmatch(norm(q), "%S+") do
        local sc = word_score(e, w)
        if not sc then return nil end
        total += sc
    end
    return total
end

local fnd_entry
local function fnd_rank()
    local q = string.lower(string.gsub(text.fq or "", "^%s+", ""))
    fact.fq_empty = q == ""
    local scored = {}
    if fnd_scope and q == "" then
        local key = SORTS[fnd_sort_i]
        local list = {}
        for _, e in ipairs(fnd_children) do list[#list + 1] = e end
        table.sort(list, function(a, b)
            if a.dir ~= b.dir then return a.dir end
            local x, y
            if key == "modified" then x, y = (b.mtime or 0), (a.mtime or 0)       -- newest first
            elseif key == "size" then x, y = (b.size or 0), (a.size or 0)         -- largest first
            elseif key == "type" then x, y = ext_of(a.path) .. "\0" .. a.low_name, ext_of(b.path) .. "\0" .. b.low_name
            else x, y = a.low_name, b.low_name end
            if x == y then return a.low_name < b.low_name end
            if fnd_sort_rev then return x > y end
            return x < y
        end)
        for _, e in ipairs(list) do scored[#scored + 1] = { e = e, s = 0 } end
    elseif fnd_scope then
        local pre = fnd_scope .. "/"
        for _, e in ipairs(fnd_all) do
            if string.sub(e.path, 1, #pre) == pre then
                local direct = not string.find(e.path, "/", #pre + 1, true)
                if q == "" then
                    if direct then scored[#scored + 1] = { e = e, s = (e.dir and 1000 or 0) - string.byte(e.low_name) / 1000 } end
                else
                    local s = fuzzy(e, q)
                    if s then scored[#scored + 1] = { e = e, s = s + frecency(e.path) * 3 } end
                end
            end
        end
        if q == "" then
            table.sort(scored, function(a, b)
                if a.e.dir ~= b.e.dir then return a.e.dir end
                return a.e.low_name < b.e.low_name
            end)
        end
    elseif q == "" then
        -- Pinned first, in their order; then the frecent ones.
        local pinned = {}
        for k, pth in ipairs(fnd_store.pins or {}) do
            local e = fnd_by_path[pth]
            if e then scored[#scored + 1] = { e = e, s = 1e9 - k }; pinned[pth] = true end
        end
        for _, e in ipairs(fnd_all) do
            local f = frecency(e.path)
            if f > 0 and not pinned[e.path] then scored[#scored + 1] = { e = e, s = f } end
        end
        -- Nothing opened yet: the roots themselves.
        if #scored == 0 then
            for _, r in ipairs(FIND_ROOTS) do
                local e = fnd_by_path[HOME .. "/" .. r]
                if e then scored[#scored + 1] = { e = e, s = 1 } end
            end
        end
    else
        for _, e in ipairs(fnd_all) do
            local s = fuzzy(e, q)
            if s then scored[#scored + 1] = { e = e, s = s + frecency(e.path) * 3 } end
        end
    end
    if not fnd_scope or q ~= "" then table.sort(scored, function(a, b) return a.s > b.s end) end
    fnd_hits = {}
    for i = 1, math.min(#scored, 400) do fnd_hits[i] = scored[i].e end
end

local fnd_preview
-- Where you are, as a breadcrumb: Files (the whole list), then the root folder it is in and
-- each folder down to this one. A long way down keeps Files, an … for what is between, and the
-- last two. Each crumb takes you there; the last one (here) copies its path.
local fnd_crumb_paths = {}
local function fnd_crumbs()
    local list = { { name = "Files", path = false } }
    if fnd_scope then
        local base = nil
        for _, r in ipairs(FIND_ROOTS) do
            local rp = HOME .. "/" .. r
            if fnd_scope == rp or string.sub(fnd_scope, 1, #rp + 1) == rp .. "/" then base = HOME end
        end
        base = base or ""
        local acc = base
        for seg in string.gmatch(string.sub(fnd_scope, #base + 2), "[^/]+") do
            acc = acc .. "/" .. seg
            list[#list + 1] = { name = seg, path = acc }
        end
    end
    local function chars() local c = 0; for _, x in ipairs(list) do c += #x.name + 3 end; return c end
    if #list > 4 or chars() > 34 then
        local n = #list
        list = chars() > 34 and n > 3 and { list[1], { name = "…", path = list[n - 1].path }, list[n] }
            or { list[1], { name = "…", path = list[n - 2].path }, list[n - 1], list[n] }
    end
    -- Still too long for the header (a long folder name): the longest name gives way, ending in …,
    -- so nothing is cut off by the sort beside it.
    local function len(x) return utf8.len(x) or #x end
    for _ = 1, 80 do
        local total = 0
        for _, x in ipairs(list) do total += len(x.name) + 3 end
        if total <= 27 then break end
        local k = nil
        for i, x in ipairs(list) do
            if x.name ~= "…" and i > 1 and (not k or len(x.name) > len(list[k].name)) then k = i end
        end
        if not k or len(list[k].name) <= 4 then break end
        local name = string.gsub(list[k].name, "…$", "")
        local cut = utf8.offset(name, len(name)) or #name
        list[k] = { name = string.sub(name, 1, cut - 1) .. "…", path = list[k].path }
    end
    local rows = {}
    fnd_crumb_paths = {}
    for i, c in ipairs(list) do
        rows[i] = { name = c.name, last = i == #list }
        fnd_crumb_paths[i] = c.path
    end
    model.fcrumbs = rows
end

local function fnd_show()
    -- Inside a folder, single-line rows: twelve of them; a search's rows say where each is, ten of
    -- them. As icons (V), a grid of four by four, scrolled a row at a time.
    local listing = fnd_scope ~= nil and fact.fq_empty
    local icons = false
    FIND_ROWS = listing and 12 or 10
    fact.fnd_listing = listing
    local n = #fnd_hits
    fnd_sel = math.clamp(fnd_sel, 0, math.max(0, n - 1))
    if icons then
        local row, top = fnd_sel // 4, fnd_off // 4
        if row < top then top = row end
        if row >= top + 4 then top = row - 3 end
        fnd_off = math.clamp(top, 0, math.max(0, (n - 1) // 4 - 3)) * 4
    else
        if fnd_sel < fnd_off then fnd_off = fnd_sel end
        if fnd_sel >= fnd_off + FIND_ROWS then fnd_off = fnd_sel - FIND_ROWS + 1 end
        fnd_off = math.clamp(fnd_off, 0, math.max(0, n - FIND_ROWS))
    end
    fnd_crumbs()
    -- Dragged out, a row is its file; a marked one, every file marked (one per line).
    local marked_paths = ""
    if fnd_nmarks > 1 then
        local list = {}
        for pth in pairs(fnd_marked) do list[#list + 1] = pth end
        table.sort(list)
        marked_paths = table.concat(list, "\n")
    end
    local rows = {}
    for i = fnd_off + 1, math.min(fnd_off + FIND_ROWS, n) do
        local e = fnd_hits[i]
        local pin = 0
        for k, pth in ipairs(fnd_store.pins or {}) do if pth == e.path then pin = k end end
        rows[#rows + 1] = { name = e.name, sub = listing and "" or tilde(e.parent), kind = kind_of(e), sel = (i - 1) == fnd_sel, pin = pin,
            ic = ficon.of(e.name, e.dir, e.path), date = select(1, fmt_parts(e)), size = select(2, fmt_parts(e)),
            icl = icons and ficon.of(e.name, e.dir, e.path) or "",
            mark = fnd_marked[e.path] == true, cut = fnd_reg ~= nil and fnd_reg.mode == "cut" and fnd_reg.set[e.path] == true,
            drag = (fnd_marked[e.path] and fnd_nmarks > 1) and marked_paths or e.path }
    end
    model.fhits = rows
    text.fnd_title = fnd_scope and tilde(fnd_scope) or "Files"
    fact.fnd_scoped = fnd_scope ~= nil
    text.fnd_sort = SORT_LABEL[SORTS[fnd_sort_i]] .. (fnd_sort_rev and " ↓" or " ↑")
    fact.fnd_marks = fnd_nmarks
    fnd_preview(fnd_hits[fnd_sel + 1])
end

fnd_entry = function(path, dir)
    local parent, name = string.match(path, "^(.*)/([^/]+)$")
    if not name then return nil end
    local low_name = string.lower(name)
    return { path = path, name = name, low_name = low_name, low = string.lower(tilde(path)), parent = parent, dir = dir,
        n_name = norm(low_name), n_path = norm(string.lower(tilde(path))) }
end

-- What is in a folder, with sizes and times, in one `find`.
local function fnd_load(dir, then_)
    run("find", { dir, "-mindepth", "1", "-maxdepth", "1", "-printf", "%y\t%s\t%T@\t%f\n" }, function(out)
        local list = {}
        for l in string.gmatch(out or "", "[^\n]+") do
            local y, size, t, name = string.match(l, "^(%a)\t(%d+)\t([%d%.]+)\t(.+)$")
            if name and (fnd_hidden_on or string.sub(name, 1, 1) ~= ".") then
                local e = fnd_entry(dir .. "/" .. name, y == "d")
                if e then e.size, e.mtime = tonumber(size), tonumber(t); list[#list + 1] = e end
            end
        end
        if fnd_scope == dir then fnd_children = list end
        if then_ then then_() end
    end)
end

local function fnd_index(after_)
    local dirs = {}
    for _, r in ipairs(FIND_ROOTS) do dirs[#dirs + 1] = HOME .. "/" .. r end
    local all, by = {}, {}
    local function add(path, dir)
        path = string.gsub(path, "/$", "")
        if by[path] then return end
        local e = fnd_entry(path, dir)
        if not e then return end
        all[#all + 1], by[path] = e, e
    end
    -- The roots themselves are entries too.
    for _, d in ipairs(dirs) do add(d, true) end
    local args_d = { "-t", "d", "-E", "node_modules", "." }
    local args_f = { "-t", "f", "-E", "node_modules", "." }
    for _, d in ipairs(dirs) do args_d[#args_d + 1] = d; args_f[#args_f + 1] = d end
    run("fd", args_d, function(out)
        for l in string.gmatch(out or "", "[^\n]+") do add(l, true) end
        run("fd", args_f, function(out2)
            for l in string.gmatch(out2 or "", "[^\n]+") do add(l, false) end
            fnd_all, fnd_by_path = all, by
            if after_ then after_() end
        end)
    end)
end

local function fnd_refresh() fnd_rank(); fnd_show() end

-- ── the preview ──
local function human(bytes)
    bytes = tonumber(bytes) or 0
    if bytes < 1024 then return bytes .. " B" end
    if bytes < 1048576 then return string.format("%.0f KB", bytes / 1024) end
    if bytes < 1073741824 then return string.format("%.1f MB", bytes / 1048576) end
    return string.format("%.1f GB", bytes / 1073741824)
end
local function when(t)
    local d = os.time() - (tonumber(t) or os.time())
    if d < 60 then return "just now" end
    if d < 3600 then return math.floor(d / 60) .. " min ago" end
    if d < 86400 then return math.floor(d / 3600) .. " h ago" end
    if d < 2592000 then return math.floor(d / 86400) .. " d ago" end
    return os.date("%d %b %Y", tonumber(t))
end
fmt_parts = function(e)
    return e.mtime and when(e.mtime) or "", (not e.dir and e.size) and human(e.size) or ""
end
fmt_meta = function(e)
    if e.dir then return "Folder · " .. when(e.mtime) end
    return human(e.size) .. " · " .. when(e.mtime)
end
-- The picture's room: the preview's width less its margins (narrower beside a large view).
local VW, VH = 624, 400
local pic_w, pic_h = 16, 9
local function fit_pic(w, h)
    w, h = tonumber(w) or 16, tonumber(h) or 9
    pic_w, pic_h = w, h
    local k = math.min(VW / w, VH / h, 2)
    fact.pv_iw = math.max(40, math.floor(w * k + 0.5))
    fact.pv_ih = math.max(30, math.floor(h * k + 0.5))
    -- The picture arrives fitted into a 624×400 canvas (the engine fills it, keeping its shape):
    -- the canvas is drawn at this scale so the picture in it is exactly the frame's size.
    fact.pv_cs = (w * k) / (w * math.min(624 / w, 400 / h))
end
-- Looking closer (v, or a click): the zoom (1 = all of it in view) and how far
-- it is moved, kept inside the picture so it never slides off into nothing.
local pv_z, pv_px, pv_py, pv_doc = 1, 0, 0, false
local function pv_view()
    local mx = math.max(0, (fact.pv_iw * pv_z - VW) / 2)
    local my = math.max(0, (fact.pv_ih * pv_z - VH) / 2)
    pv_px, pv_py = math.clamp(pv_px, -mx, mx), math.clamp(pv_py, -my, my)
    fact.pv_z, fact.pv_px, fact.pv_py = pv_z, pv_px, pv_py
    text.pv_zoom = math.floor(pv_z * 100 + 0.5) .. "%  ·  K J zoom · h j k l move · 0 whole · w width · Esc back"
end
local function pv_zoom_to(z)
    z = math.clamp(z, 1, 6)
    local first = pv_z < 1.01 and z >= 1.01
    pv_px, pv_py = pv_px * z / pv_z, pv_py * z / pv_z
    pv_z = z
    if first and pv_doc then pv_py = math.huge end   -- a page is read from its top
    pv_view()
end
local function pv_reset()
    pv_z, pv_px, pv_py = 1, 0, 0
    fact.fnd_view = false
    pv_view()
end
local function pv_picture(gen, path, meta_prefix, own_size, doc)
    run("magick", { "identify", "-format", "%w %h\n", path .. "[0]" }, function(out)
        if gen ~= fnd_pv_gen then return end
        local w, h = string.match(out or "", "(%d+) (%d+)")
        fit_pic(w, h)
        pv_doc = doc or false
        pv_reset()
        -- With this preview's number on it: the same file drawn into again
        -- (the PDF and video previews take turns in two) is a new picture.
        text.pv_img_path = path .. "?" .. gen
        if meta_prefix then text.pv_meta = meta_prefix .. ((own_size and w) and (" · " .. w .. " × " .. h) or "") end
        fact.pv_kind = 2
    end)
end

-- A document's words, out of its XML: paragraphs to lines, tags out, entities in.
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
-- A page with its empty margins trimmed, so the words fill what room there is.
local function page_trim(png, done)
    run("magick", { png, "-fuzz", "10%", "-trim", "+repage", "-bordercolor", "white", "-border", "3%", png }, function() done() end)
end
-- LibreOffice is slow to start: one render at a time, the latest one asked
-- for next, and each kept (by path and time) so it is only ever made once.
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
    if gen ~= fnd_pv_gen then return end
    text.pv_text = string.sub(txt, 1, 3000)
    if meta then text.pv_meta = meta end
    fact.pv_kind = 6
end
local function dur(sec)
    sec = math.floor((tonumber(sec) or 0) + 0.5)
    if sec >= 3600 then return string.format("%d:%02d:%02d", sec // 3600, sec % 3600 // 60, sec % 60) end
    return string.format("%d:%02d", sec // 60, sec % 60)
end

fnd_preview = function(e)
    fnd_pv_gen += 1
    local gen = fnd_pv_gen
    pv_reset()
    if not e then text.pv_name = ""; text.pv_meta = ""; fact.pv_kind = 0; return end
    text.pv_name = e.name
    text.pv_meta = tilde(e.parent)
    -- A moment's pause first: holding j does not start a preview per row.
    after(90, function()
        if gen ~= fnd_pv_gen then return end
        if e.dir then
            run("fd", { "-d", "1", ".", e.path }, function(out)
                if gen ~= fnd_pv_gen then return end
                local ds, fs = {}, {}
                for l in string.gmatch(out or "", "[^\n]+") do
                    local name = string.match(string.gsub(l, "/$", ""), "([^/]+)$")
                    if name then if string.sub(l, -1) == "/" then ds[#ds + 1] = name .. "/" else fs[#fs + 1] = name end end
                end
                table.sort(ds); table.sort(fs)
                -- What is in it, as Finder's icons: folders first, then files; what does not fit, counted.
                local tiles = {}
                for _, x in ipairs(ds) do tiles[#tiles + 1] = { name = string.gsub(x, "/$", ""), dir = true } end
                for _, x in ipairs(fs) do tiles[#tiles + 1] = { name = x, dir = false } end
                local total = #tiles
                -- As icons the last place counts what did not fit; as a list that is said under it.
                local as_list = fact.pvd_list
                local room = (total > 24 and not as_list) and 23 or 24
                local grid = {}
                for k = 1, math.min(room, total) do
                    local t = tiles[k]
                    grid[k] = { name = t.name, dir = t.dir, ic = ficon.of(t.name, t.dir, t.name) }
                end
                -- A list reads down each column, as Finder's does: the grid fills by rows, so it is handed over in that order.
                if as_list then
                    local n, rows = #grid, math.ceil(#grid / 2)
                    local down = {}
                    for r = 1, rows do
                        down[#down + 1] = grid[r]
                        if r + rows <= n then down[#down + 1] = grid[r + rows] else down[#down + 1] = { name = "", dir = false, ic = "" } end
                    end
                    while #down > n and down[#down].name == "" do down[#down] = nil end
                    grid = down
                end
                model.pvd = grid
                fact.pvd_more = math.max(0, total - room)
                text.pv_meta = total .. (total == 1 and " item · " or " items · ") .. tilde(e.parent)
                text.pv_text = total == 0 and "Empty folder" or ""
                fact.pv_kind = 7
            end)
            return
        end
        run("stat", { "-c", "%s %Y", e.path }, function(out)
            if gen ~= fnd_pv_gen then return end
            local size, t = string.match(out or "", "(%d+) (%d+)")
            local meta = human(size) .. " · " .. when(t)
            text.pv_meta = meta
            local k = kind_of(e)
            if k == 2 then
                pv_picture(gen, e.path, meta, true)
            elseif k == 3 or k == 4 then
                -- A PDF's first page, a video's frame: drawn into a file of the scene's own.
                fnd_pv_slot = 1 - fnd_pv_slot
                local out_png = folder .. "/finder-pv" .. fnd_pv_slot
                local cmd, args
                if k == 3 then cmd, args = "pdftoppm", { "-png", "-f", "1", "-l", "1", "-singlefile", "-scale-to", "2400", e.path, out_png }
                else cmd, args = "ffmpeg", { "-y", "-loglevel", "error", "-ss", "1", "-i", e.path, "-frames:v", "1", "-vf", "scale=900:-2", out_png .. ".png" } end
                run(cmd, args, function(_, code)
                    if gen ~= fnd_pv_gen then return end
                    if code ~= 0 then fact.pv_kind = 4; return end
                    if k == 3 then
                        page_trim(out_png .. ".png", function() pv_picture(gen, out_png .. ".png", "PDF · " .. meta, nil, true) end)
                        return
                    end
                    run("ffprobe", { "-v", "error", "-select_streams", "v:0", "-show_entries", "stream=width,height:format=duration", "-of", "csv=p=0", e.path }, function(info)
                        if gen ~= fnd_pv_gen then return end
                        local w, h = string.match(info or "", "(%d+),(%d+)")
                        local d = string.match(info or "", "\n%s*([%d%.]+)") or string.match(info or "", "^([%d%.]+)")
                        pv_picture(gen, out_png .. ".png", "Video · " .. (d and (dur(d) .. " · ") or "") .. (w and (w .. "×" .. h .. " · ") or "") .. meta)
                    end)
                end)
            elseif OFFICE_EXT[ext_of(e.path)] then
                -- The words at once, then the first page once LibreOffice has drawn it.
                local x = ext_of(e.path)
                local kind_name = (x == "pptx" or x == "ppt" or x == "odp") and "Presentation" or (x == "xlsx" or x == "xls" or x == "ods") and "Spreadsheet" or "Document"
                text.pv_meta = kind_name .. " · " .. meta
                if OFFICE_XML[x] then
                    run("unzip", { "-p", e.path, OFFICE_XML[x] }, function(xml)
                        if gen ~= fnd_pv_gen or fact.pv_kind == 2 then return end
                        local words = xml_text(xml or "")
                        prose(gen, words ~= "" and words or "(no text)")
                    end)
                else
                    prose(gen, "Rendering a preview…")
                end
                render_office({ path = e.path, t = t or "0", ready = function(png)
                    if gen == fnd_pv_gen then pv_picture(gen, png, kind_name .. " · " .. meta, nil, true) end
                end })
            elseif ARC_EXT[ext_of(e.path)] then
                run("bsdtar", { "-tf", e.path }, function(out2, code)
                    if gen ~= fnd_pv_gen then return end
                    if code ~= 0 then fact.pv_kind = 4; return end
                    local lines = {}
                    for l in string.gmatch(out2 or "", "[^\n]+") do lines[#lines + 1] = l end
                    text.pv_meta = "Archive · " .. #lines .. " items · " .. meta
                    text.pv_text = table.concat(lines, "\n", 1, math.min(#lines, 24))
                    fact.pv_kind = 3
                end)
            elseif AUD_EXT[ext_of(e.path)] then
                run("ffprobe", { "-v", "error", "-show_entries", "format=duration:format_tags=title,artist,album", "-of", "default=nw=1", e.path }, function(out2)
                    if gen ~= fnd_pv_gen then return end
                    local tag = function(k2) return string.match(out2 or "", "TAG:" .. k2 .. "=([^\n]+)") end
                    local title, artist, album = tag("title") or e.name, tag("artist"), tag("album")
                    local length = dur(string.match(out2 or "", "duration=([%d%.]+)"))
                    local line = (artist and (artist .. " — ") or "") .. title .. " · " .. length
                    fnd_pv_slot = 1 - fnd_pv_slot
                    local cover = folder .. "/finder-pv" .. fnd_pv_slot .. ".png"
                    run("ffmpeg", { "-y", "-loglevel", "error", "-i", e.path, "-an", "-frames:v", "1", cover }, function(_, code)
                        if gen ~= fnd_pv_gen then return end
                        if code == 0 then pv_picture(gen, cover, line)
                        else prose(gen, title .. "\n" .. (artist or "") .. "\n" .. (album or "") .. "\n\n" .. length, "Audio · " .. meta) end
                    end)
                end)
            elseif FONT_EXT[ext_of(e.path)] then
                fnd_pv_slot = 1 - fnd_pv_slot
                local sheet = folder .. "/finder-pv" .. fnd_pv_slot .. ".png"
                run("magick", { "-size", "928x620", "xc:#1b1925", "-font", e.path, "-fill", "#f6f8fc",
                    "-pointsize", "120", "-annotate", "+44+160", "Aa Gg",
                    "-pointsize", "52", "-annotate", "+44+270", "The quick brown fox",
                    "-annotate", "+44+340", "jumps over the lazy dog",
                    "-pointsize", "40", "-annotate", "+44+440", "0123456789 !?&@#%",
                    "-pointsize", "28", "-annotate", "+44+520", "ABCDEFGHIJKLMNOPQRSTUVWXYZ", sheet }, function(_, code)
                    if gen ~= fnd_pv_gen then return end
                    if code == 0 then pv_picture(gen, sheet, "Font · " .. meta) else fact.pv_kind = 4 end
                end)
            elseif k == 5 or (k == 0 and (tonumber(size) or 0) < 2000000) then
                run("head", { "-c", "6000", e.path }, function(txt)
                    if gen ~= fnd_pv_gen then return end
                    txt = txt or ""
                    if string.find(txt, "\0", 1, true) then fact.pv_kind = 4; return end
                    local lines, n = {}, 0
                    for l in string.gmatch(txt, "([^\n]*)\n?") do
                        n += 1
                        if n > 29 then break end
                        l = string.gsub(l, "\t", "    ")
                        if utf8.len(l) and utf8.len(l) > 96 then l = string.sub(l, 1, utf8.offset(l, 96) - 1) .. "…" end
                        lines[#lines + 1] = l
                    end
                    text.pv_text = table.concat(lines, "\n")
                    fact.pv_kind = 1
                end)
            else
                run("file", { "-b", e.path }, function(desc)
                    if gen ~= fnd_pv_gen then return end
                    desc = string.gsub(desc or "", "%s+$", "")
                    if #desc > 60 then desc = string.sub(desc, 1, 60) .. "…" end
                    text.pv_meta = (desc ~= "" and (desc .. " · ") or "") .. meta
                    fact.pv_kind = 4
                end)
            end
        end)
    end)
end

-- ── opening, and remembering what was opened ──
local function fnd_remember(path)
    local h = fnd_store.hits[path] or { n = 0 }
    h.n, h.t = (h.n or 0) + 1, os.time()
    fnd_store.hits[path] = h
    pcall(sys.call, "files.write", "finder.json", fnd_store)
end
-- Never a new terminal: the one there is (Ghostty, with tmux in it) gets a
-- new tmux window, and is brought to the front.
local function to_terminal()
    run(SCRIPTS .. "wm.sh", { "focus-class", "com.mitchellh.ghostty" }, nil, { output = false })
end
local function tmux_window(dir, cmd)
    local args = { "new-window", "-c", dir }
    for _, a in ipairs(cmd or {}) do args[#args + 1] = a end
    run("tmux", args, function(_, code)
        if code == 0 then to_terminal()
        else text.fnd_toast = "No tmux session is running"; fact.fnd_toast_seq = fact.fnd_toast_seq + 1 end
    end)
end
local function fnd_launch(e)
    fnd_remember(e.path)
    fact.expanded = false
    if TEXT_EXT[ext_of(e.path)] then
        tmux_window(e.parent, { "nvim", e.path })
    else
        run("xdg-open", { e.path }, nil, { output = false })
    end
end
local function fnd_toast(msg)
    text.fnd_toast = msg
    fact.fnd_toast_seq = fact.fnd_toast_seq + 1
end
-- Where the cursor is, kept for the folder showing (not while searching: that list is the search's).
local function fnd_note_cursor()
    local e = fnd_hits[fnd_sel + 1]
    if e and (text.fq or "") == "" then fnd_cursor[fnd_scope or ""] = e.path end
end
-- Leaving this folder for another: it goes in the history, and forward is forgotten.
local function fnd_push_history()
    fnd_note_cursor()
    table.insert(fnd_back, fnd_scope or false)
    if #fnd_back > 50 then table.remove(fnd_back, 1) end
    fnd_fwd = {}
end
-- To a folder (nil: the whole list), the cursor on `want` or where it was last time.
local function fnd_goto(scope, want)
    fnd_scope = scope or nil
    fnd_children = {}
    text.fq = ""
    fnd_sel, fnd_off = 0, 0
    local function land()
        fnd_rank()
        local target = want or fnd_cursor[fnd_scope or ""]
        if target then for i, x in ipairs(fnd_hits) do if x.path == target then fnd_sel = i - 1 end end end
        fnd_show()
    end
    if fnd_scope then fnd_load(fnd_scope, land) else land() end
end
local function fnd_enter(e)
    if not e then return end
    if e.dir then
        fnd_push_history()
        fnd_remember(e.path)
        fnd_goto(e.path)
    else
        fnd_launch(e)
    end
end

on("fnd_open", function() fnd_enter(fnd_hits[fnd_sel + 1]) end)
on("fnd_open_row", function(i) fnd_sel = fnd_off + i; fnd_enter(fnd_hits[fnd_sel + 1]) end)
on("fnd_up", function()
    if not fnd_scope then return end
    fnd_push_history()
    local was = fnd_scope
    local parent = string.match(fnd_scope, "^(.*)/[^/]+$")
    -- Above a root is the whole list again.
    local inside = false
    for _, r in ipairs(FIND_ROOTS) do
        local root = HOME .. "/" .. r
        if parent and string.sub(parent, 1, #root) == root then inside = true end
    end
    fnd_scope = inside and parent or nil
    text.fq = ""
    local function land()
        fnd_rank()
        -- Land on the folder just left.
        fnd_sel, fnd_off = 0, 0
        for i, e in ipairs(fnd_hits) do if e.path == was then fnd_sel = i - 1 end end
        fnd_show()
    end
    if fnd_scope then fnd_load(fnd_scope, land) else land() end
end)
on("fnd_thunar", function()
    local e = fnd_hits[fnd_sel + 1]
    local dir = e and (e.dir and e.path or e.parent) or fnd_scope or HOME
    fnd_remember(dir)
    fact.expanded = false
    run("thunar", { dir }, nil, { output = false })
end)
on("fnd_move", function(d)
    help_on = false; fact.fnd_help_on = false
    fnd_sel += d; fnd_show()
end)
-- How a folder's contents show in the preview: icons, or a list (V, or the
-- preview's switch); remembered. The results on the left are always a list.
on("fnd_view_as", function(v)
    local list = v == 0 or (v < 0 and not fact.pvd_list)
    fact.pvd_list = list
    fnd_store.pv_view = list and "list" or "icons"
    pcall(sys.call, "files.write", "finder.json", fnd_store)
    fnd_show()
end)
-- A crumb: that folder (Files is the whole list). (The one you are in copies its path: the scene says so.)
on("fnd_crumb", function(i)
    local path = fnd_crumb_paths[i + 1]
    if path == nil or i + 1 == #fnd_crumb_paths then return end
    fnd_push_history()
    local was = fnd_scope
    text.fq = ""
    fnd_sel, fnd_off = 0, 0
    if path == false then
        fnd_scope = nil
        fnd_refresh()
        return
    end
    fnd_scope = path
    fnd_children = {}
    fnd_load(path, function()
        fnd_rank()
        -- Land on the folder just come up from.
        for k, e in ipairs(fnd_hits) do
            if was and (e.path == was or string.sub(was, 1, #e.path + 1) == e.path .. "/") then fnd_sel = k - 1 end
        end
        fnd_show()
    end)
end)
-- p: pin or unpin what is chosen (harpoon's marks): the pinned stay on top, numbered, and 1–4 open them.
on("fnd_pin", function()
    local e = fnd_hits[fnd_sel + 1]
    if not e then return end
    fnd_store.pins = fnd_store.pins or {}
    local at
    for k, pth in ipairs(fnd_store.pins) do if pth == e.path then at = k end end
    if at then table.remove(fnd_store.pins, at) else table.insert(fnd_store.pins, e.path) end
    pcall(sys.call, "files.write", "finder.json", fnd_store)
    fnd_show()
end)
on("fnd_jump", function(k)
    local pth = (fnd_store.pins or {})[k]
    local e = pth and fnd_by_path[pth]
    if e then fnd_enter(e) end
end)
-- yd: the path of the folder showing (or, in the whole list, the chosen one's folder).
on("fnd_yank_dir", function()
    local e = fnd_hits[fnd_sel + 1]
    local dir = fnd_scope or (e and (e.dir and e.path or e.parent))
    if not dir then return end
    pcall(sys.call, "clipboard.set", dir)
    text.fnd_toast = "Copied " .. tilde(dir)
    fact.fnd_toast_seq = fact.fnd_toast_seq + 1
end)
-- y: the full path, to the clipboard.
on("fnd_yank", function()
    local e = fnd_hits[fnd_sel + 1]
    if not e then return end
    pcall(sys.call, "clipboard.set", e.path)
    text.fnd_toast = "Copied " .. tilde(e.path)
    fact.fnd_toast_seq = fact.fnd_toast_seq + 1
end)
-- t: the folder (or a file's) as a tmux session, as sesh does from Super+A, on the terminal's workspace.
on("fnd_tmux", function()
    local e = fnd_hits[fnd_sel + 1]
    local dir = e and (e.dir and e.path or e.parent) or fnd_scope
    if not dir then return end
    fnd_remember(dir)
    fact.expanded = false
    run("tmux", { "run-shell", "sesh connect '" .. string.gsub(dir, "'", "'\\''") .. "'" }, function(_, code)
        if code == 0 then to_terminal()
        else text.fnd_toast = "No tmux session is running"; fact.fnd_toast_seq = fact.fnd_toast_seq + 1 end
    end)
end)
-- e: in Neovim, whatever it is (a folder: Neovim's own file browser there).
on("fnd_edit", function()
    local e = fnd_hits[fnd_sel + 1]
    if not e then return end
    fnd_remember(e.path)
    fact.expanded = false
    tmux_window(e.dir and e.path or e.parent, { "nvim", e.path })
end)
on("fnd_scroll", function(w)
    local step = 1
    fnd_off = math.clamp(fnd_off + (w > 0 and -step or step), 0, math.max(0, #fnd_hits - FIND_ROWS))
    if step == 4 then fnd_off -= fnd_off % 4 end
    fnd_sel = math.clamp(fnd_sel, fnd_off, fnd_off + FIND_ROWS - 1)
    fnd_show()
end)
on("pv_zoom", function(f) pv_zoom_to(pv_z * f) end)
on("pv_fit", function() pv_zoom_to(1) end)
on("pv_width", function()
    -- As wide as the panel (a page's lines end to end), from its top.
    pv_zoom_to(math.max(1, VW / math.max(1, fact.pv_iw)))
    if pv_doc then pv_py = math.huge end
    pv_view()
end)
on("pv_pan_x", function(d) pv_px += d; pv_view() end)
on("pv_pan_y", function(d) pv_py += d; pv_view() end)
on("pv_end", function(d) pv_py = d * math.huge; pv_view() end)
-- A drag moves it from where it was when grabbed.
local grab_x, grab_y = 0, 0
on("pv_grab", function() grab_x, grab_y = pv_px, pv_py end)
on("pv_drag_x", function(d) pv_px = grab_x + d; pv_view() end)
on("pv_drag_y", function(d) pv_py = grab_y + d; pv_view() end)
on("fq_clear", function() text.fq = ""; fnd_sel, fnd_off = 0, 0; fnd_refresh() end)

-- ── the file manager ──
local function toast(msg) text.fnd_toast = msg; fact.fnd_toast_seq = fact.fnd_toast_seq + 1 end
local function chosen()
    -- The marked ones, or else the one under the cursor.
    local list = {}
    for pth in pairs(fnd_marked) do list[#list + 1] = pth end
    table.sort(list)
    if #list == 0 then
        local e = fnd_hits[fnd_sel + 1]
        if e then list[1] = e.path end
    end
    return list
end
local function n_items(n) return n == 1 and "1 item" or (n .. " items") end
-- After a change: the folder read again (and the index, for searches), the cursor on `name` if given.
local function after_change(name)
    fnd_marked, fnd_nmarks = {}, 0
    local function land()
        fnd_rank()
        if name then for i, e in ipairs(fnd_hits) do if e.name == name then fnd_sel = i - 1 end end end
        fnd_show()
    end
    if fnd_scope then fnd_load(fnd_scope, land) else land() end
    fnd_index()
end

on("fnd_mark", function()
    local e = fnd_hits[fnd_sel + 1]
    if not e then return end
    if fnd_marked[e.path] then fnd_marked[e.path] = nil; fnd_nmarks -= 1
    else fnd_marked[e.path] = true; fnd_nmarks += 1 end
    fnd_sel += 1
    fnd_show()
end)
on("fnd_unmark", function() fnd_marked, fnd_nmarks = {}, 0; fnd_show() end)
-- Ctrl+Shift+H beside WhatsApp: what is marked (or the one under the cursor) put over its field to
-- send, as if dragged there, and the keys go to the chat for a caption. Folders can't be sent.
on("fnd_to_view", function()
    local paths = {}
    if fnd_nmarks > 0 then
        for pth in pairs(fnd_marked) do paths[#paths + 1] = pth end
        table.sort(paths)
    else
        local e = fnd_hits[fnd_sel + 1]
        if e then
            if e.dir then return fnd_toast("A folder can't be sent: mark files in it (Space)") end
            paths[1] = e.path
        end
    end
    if #paths == 0 or not wa_hook.stage then return end
    for _, pth in ipairs(paths) do wa_hook.stage(pth) end
    fnd_marked, fnd_nmarks = {}, 0
    fnd_show()
    fact.side_focus = false
end)
local function take(mode)
    local list = chosen()
    if #list == 0 then return end
    local set = {}
    for _, pth in ipairs(list) do set[pth] = true end
    fnd_reg = { mode = mode, paths = list, set = set }
    fnd_marked, fnd_nmarks = {}, 0
    toast((mode == "copy" and "Copied " or "Cut ") .. n_items(#list) .. " · p to paste")
    fnd_show()
end
on("fnd_copy", function() take("copy") end)
on("fnd_cut", function() take("cut") end)
on("fnd_paste", function()
    if not fnd_reg then toast("Nothing to paste: yy copies, dd cuts"); return end
    if not fnd_scope then toast("Step into a folder to paste there"); return end
    local reg, dest = fnd_reg, fnd_scope
    -- A name already there gets " (copy)", " (copy 2)"… as Thunar does; nothing is overwritten.
    local taken = {}
    for _, e in ipairs(fnd_children) do taken[e.name] = true end
    local jobs, first = {}, nil
    for _, src in ipairs(reg.paths) do
        local name = string.match(src, "([^/]+)$")
        local same_place = string.match(src, "^(.*)/[^/]+$") == dest
        if not (reg.mode == "cut" and same_place) then
            local out = name
            if taken[out] then
                local stem, ext = string.match(name, "^(.+)(%.[^%.]+)$")
                if not stem or string.find(src, "/$") then stem, ext = name, "" end
                local k = 1
                repeat
                    out = stem .. (k == 1 and " (copy)" or (" (copy " .. k .. ")")) .. ext
                    k += 1
                until not taken[out]
            end
            taken[out] = true
            first = first or out
            jobs[#jobs + 1] = { src = src, dst = dest .. "/" .. out }
        end
    end
    local done, failed = 0, 0
    local function step(i)
        local j = jobs[i]
        if not j then
            if failed == 0 then toast((reg.mode == "copy" and "Pasted " or "Moved ") .. n_items(done))
            else toast("Pasted " .. done .. ", " .. failed .. " could not be") end
            if reg.mode == "cut" then fnd_reg = nil end
            after_change(first)
            return
        end
        local cmd, args = "mv", { "-n", j.src, j.dst }
        if reg.mode == "copy" then cmd, args = "cp", { "-r", "-n", j.src, j.dst } end
        run(cmd, args, function(_, code)
            if code == 0 then done += 1 else failed += 1 end
            step(i + 1)
        end)
    end
    step(1)
end)
on("fnd_trash", function()
    local list = chosen()
    if #list == 0 then return end
    local args = { "trash" }
    for _, pth in ipairs(list) do args[#args + 1] = pth end
    run("gio", args, function(_, code)
        toast(code == 0 and ("Moved " .. n_items(#list) .. " to the Trash") or "Could not move it to the Trash")
        fnd_sel = math.max(0, fnd_sel - 0)
        after_change()
    end)
end)
-- r, a, A: a name to type, in the field that rises over the list.
local function ask(kind, label, prefill, target)
    fnd_prompt_kind, fnd_prompt_for = kind, target
    text.fnd_prompt_label = label
    text.fnd_in = prefill or ""
    fact.fnd_prompting = true
end
on("fnd_rename", function()
    local e = fnd_hits[fnd_sel + 1]
    if e then ask("rename", "RENAME", e.name, e) end
end)
on("fnd_new", function(folder_)
    if not fnd_scope then toast("Step into a folder to make something there"); return end
    ask(folder_ == 1 and "folder" or "file", folder_ == 1 and "NEW FOLDER" or "NEW FILE", "", nil)
end)
on("fnd_prompt_ok", function()
    local name = string.gsub(string.gsub(text.fnd_in or "", "^%s+", ""), "%s+$", "")
    if name == "" or string.find(name, "/", 1, true) then toast("A name, without a /"); return end
    local kind, e = fnd_prompt_kind, fnd_prompt_for
    fnd_prompt_kind, fnd_prompt_for = nil, nil
    if kind == "rename" and e then
        if name == e.name then return end
        run("mv", { "-n", e.path, e.parent .. "/" .. name }, function(_, code)
            toast(code == 0 and ("Renamed to " .. name) or "Could not rename it")
            local h = fnd_store.hits[e.path]
            if code == 0 and h then fnd_store.hits[e.parent .. "/" .. name] = h; fnd_store.hits[e.path] = nil end
            after_change(name)
        end)
    elseif kind == "folder" then
        run("mkdir", { "-p", fnd_scope .. "/" .. name }, function(_, code)
            toast(code == 0 and ("Made " .. name) or "Could not make it"); after_change(name)
        end)
    elseif kind == "file" then
        run("touch", { fnd_scope .. "/" .. name }, function(_, code)
            toast(code == 0 and ("Made " .. name) or "Could not make it"); after_change(name)
        end)
    end
end)
on("fnd_sort", function(d)
    if d < 0 then fnd_sort_rev = not fnd_sort_rev
    else fnd_sort_i = fnd_sort_i % #SORTS + 1; fnd_sort_rev = false end
    local was = fnd_hits[fnd_sel + 1]
    fnd_rank()
    fnd_sel = 0
    if was then for i, e in ipairs(fnd_hits) do if e.path == was.path then fnd_sel = i - 1 end end end
    fnd_show()
    if not fnd_scope then toast("Sorting is for inside a folder") end
end)
on("fnd_hidden", function()
    fnd_hidden_on = not fnd_hidden_on
    toast(fnd_hidden_on and "Showing hidden files" or "Hiding hidden files")
    if fnd_scope then fnd_load(fnd_scope, fnd_refresh) end
end)
on("fnd_top", function()
    if fnd_scope then fnd_push_history() end
    fnd_goto(nil)
end)
-- H and L (Alt+Left/Right): back and forward through the folders walked.
on("fnd_back", function()
    if #fnd_back == 0 then return fnd_toast("Nothing further back") end
    fnd_note_cursor()
    table.insert(fnd_fwd, fnd_scope or false)
    fnd_goto(table.remove(fnd_back) or nil)
end)
on("fnd_forward", function()
    if #fnd_fwd == 0 then return fnd_toast("Nothing further forward") end
    fnd_note_cursor()
    table.insert(fnd_back, fnd_scope or false)
    fnd_goto(table.remove(fnd_fwd) or nil)
end)
on("fnd_term", function()
    local e = fnd_hits[fnd_sel + 1]
    local dir = e and (e.dir and e.path or e.parent) or fnd_scope or HOME
    fnd_remember(dir)
    fact.expanded = false
    tmux_window(dir)
end)
local HELP = table.concat({
    "Move     j k · gg G · Ctrl+d u",
    "         l ⏎ into · h - up · ~ top",
    "History  H back · L forward (Alt+← →)",
    "Open     ⏎ l · e Neovim (tmux) · o Thunar",
    "Terminal t tmux session · T tmux window",
    "Search   i / · Ctrl+j k while typing",
    "Select   Space mark · Esc unmark",
    "Files    yy copy · dd cut · p paste",
    "         dD to Trash · r rename",
    "         a new file · A new folder",
    "Path     yp the chosen one's · yd the folder's",
    "Sort     s cycle · S reverse",
    "         . hidden files",
    "Pins     m pin · 1–4 jump",
    "Preview  V a folder as icons or a list",
    "         v look closer (or click it)",
    "         K J zoom (+ − too) · 0 whole · w width",
    "         h j k l move · gg G top end",
    "         Ctrl+d u half · Esc v back",
    "         wheel zooms · drag moves",
    "",
    "Reopened within 5 min, it is where you left it",
    "? again to close",
}, "\n")
on("fnd_help", function()
    help_on = not help_on
    fact.fnd_help_on = help_on
    if help_on then
        fnd_pv_gen += 1
        text.fnd_help_text = HELP
        text.pv_name = "Keys"
        text.pv_meta = "Everything the finder does"
        fact.pv_kind = 5
    else
        fnd_show()
    end
end)
on("text:fq", function() fnd_sel, fnd_off = 0, 0; fnd_refresh() end)
-- Leaving the finder: where it was, for the next time (see FIND_RESUME).
local function fnd_leave()
    if not fnd_is_open then return end
    fnd_is_open = false
    fnd_note_cursor()
    local e = fnd_hits[fnd_sel + 1]
    fnd_store.last = { scope = fnd_scope, q = text.fq or "", sel = e and e.path, at = os.time() }
    pcall(sys.call, "files.write", "finder.json", fnd_store)
end
on("fact:expanded", function(v) if not v then fnd_leave() end end)
local function fnd_arrive()
    fnd_is_open = true
    fnd_marked, fnd_nmarks = {}, 0
    fnd_sel, fnd_off = 0, 0
    local last = fnd_store.last
    local want = nil
    if last and os.time() - (last.at or 0) < FIND_RESUME then
        -- Back where it was left: the folder, the search, the cursor.
        fnd_scope = last.scope
        text.fq = last.q or ""
        want = last.sel
    else
        fnd_scope = nil
        text.fq = ""
        fnd_back, fnd_fwd, fnd_cursor = {}, {}, {}
    end
    local function land()
        fnd_rank()
        if want then
            for i, x in ipairs(fnd_hits) do if x.path == want then fnd_sel = i - 1; want = nil end end
        end
        fnd_show()
    end
    if fnd_scope then
        fnd_children = {}
        fnd_load(fnd_scope, land)
    elseif #fnd_all > 0 then
        land()
    end
    fnd_index(land)
end
-- Its own page in the centre card, or beside a large view (the right capsule's card, side_k 3).
local function fnd_beside() return fact.side and fact.side_k == 3 end
on("fact:panel", function(p)
    if p == "fnd" then return fnd_arrive() end
    if not fnd_beside() then fnd_leave() end
end)
local function fnd_side_changed()
    local beside = fnd_beside()
    local w = beside and 268 or 624
    if w ~= VW then
        VW = w
        fit_pic(pic_w, pic_h)
        pv_reset()
    end
    if beside and not fnd_is_open then fnd_arrive()
    elseif not beside and fnd_is_open and fact.panel ~= "fnd" then fnd_leave() end
end
on("fact:side", fnd_side_changed)
on("fact:side_k", fnd_side_changed)
-- zoxide's history: the folders already visited, as a head start.
run("zoxide", { "query", "-l", "-s" }, function(out)
    for l in string.gmatch(out or "", "[^\n]+") do
        local s, p = string.match(l, "^%s*([%d%.]+)%s+(.+)$")
        if p then fnd_zox[p] = tonumber(s) end
    end
end)

end)()

;(function()
-- ── the dial (Timer, Keep Awake) ────────────────────────────────
-- Where its knob is says how long, in steps: fine at first, coarser further
-- on. Letting go (or Enter) starts it.
local DIAL_STEPS = {
    timer = { 1, 2, 3, 4, 5, 7, 10, 12, 15, 20, 25, 30, 40, 45, 60, 75, 90, 120, 150, 180 },
    awk = { 5, 10, 15, 20, 30, 45, 60, 90, 120, 180, 240, 360, 480, 0 },
}
local dial_at = { timer = 5, awk = 7 }     -- 5 min; 1 hour
local function dial_words(m)
    if m == 0 then return "Until off" end
    if m < 60 then return m .. " min" end
    local h, r = m // 60, m % 60
    if r == 0 then return h == 1 and "1 hour" or (h .. " hours") end
    return h .. " hr " .. r .. " min"
end
local function dial_kind() return (fact.panel == "awk") and "awk" or "timer" end
local function dial_show(set_knob)
    local k = dial_kind()
    local steps = DIAL_STEPS[k]
    local i = math.clamp(dial_at[k], 1, #steps)
    dial_at[k] = i
    local m = steps[i]
    text.dial_label = dial_words(m)
    text.dial_sub = k == "awk" and (m == 0 and "Stays awake until you turn it off" or "Let go to keep it awake") or "Let go to start"
    fact.dial_idx = i
    if set_knob then fact.dial_f = (i - 1) / (#steps - 1) end
end
local function dial_index(f)
    local steps = DIAL_STEPS[dial_kind()]
    return math.clamp(math.floor(f * (#steps - 1) + 0.5) + 1, 1, #steps)
end
on("dial_move", function(f)
    local k = dial_kind()
    local i = dial_index(f)
    if i ~= dial_at[k] then dial_at[k] = i; dial_show(false) end
end)
on("dial_step", function(d)
    local k = dial_kind()
    dial_at[k] += d
    dial_show(true)
end)
on("dial_go", function(f)
    local k = dial_kind()
    if f then dial_at[k] = dial_index(f) end
    dial_show(true)
    local m = DIAL_STEPS[k][dial_at[k]]
    if k == "timer" then tm_start_secs(m * 60) else awake_start(m) end
end)
on("fact:panel", function(p) if p == "timer" or p == "awk" then dial_show(true) end end)
end)()

-- ── the weather: Open-Meteo, for where this machine is ─────────────
-- Where comes from weather.json in the scene's folder: { lat, lon, city }.
-- Without it, it is guessed once from the IP (ipinfo.io) and kept there, so
-- writing it by hand pins another place.
local wx_where = sys.ask("files.read", "weather.json", "json") or {}
local WX_WORDS = {
    [0] = "Clear", [1] = "Mostly Clear", [2] = "Partly Cloudy", [3] = "Cloudy",
    [45] = "Foggy", [48] = "Foggy",
    [51] = "Drizzle", [53] = "Drizzle", [55] = "Drizzle", [56] = "Freezing Drizzle", [57] = "Freezing Drizzle",
    [61] = "Light Rain", [63] = "Rain", [65] = "Heavy Rain", [66] = "Freezing Rain", [67] = "Freezing Rain",
    [71] = "Light Snow", [73] = "Snow", [75] = "Heavy Snow", [77] = "Snow",
    [80] = "Showers", [81] = "Showers", [82] = "Heavy Showers", [85] = "Snow Showers", [86] = "Snow Showers",
    [95] = "Thunderstorms", [96] = "Thunderstorms", [99] = "Thunderstorms",
}
local function wx_icon(code, day)
    if code == 0 then return day and 0 or 1 end
    if code <= 2 then return day and 2 or 3 end
    if code == 3 then return 4 end
    if code == 45 or code == 48 then return 8 end
    if code >= 95 then return 7 end
    if (code >= 71 and code <= 77) or code == 85 or code == 86 then return 6 end
    return 5
end
local function deg(x) return math.floor((tonumber(x) or 0) + 0.5) .. "°" end
local function hour_name(stamp)
    local h = tonumber(string.sub(stamp or "", 12, 13)) or 0
    if h == 0 then return "12AM" elseif h < 12 then return h .. "AM" elseif h == 12 then return "12PM" end
    return (h - 12) .. "PM"
end
local wx_fetch
local function wx_show(d)
    local c = d.current
    local code, day = tonumber(c.weather_code) or 3, c.is_day == 1
    fact.wx_ic = wx_icon(code, day)
    fact.wx_sky = (not day) and 1 or (code <= 2 and 0 or ((code == 3 or code == 45 or code == 48) and 2 or 3))
    text.wx_temp = deg(c.temperature_2m)
    text.wx_cond = (day and code == 0) and "Sunny" or (WX_WORDS[code] or "")
    text.wx_hilo = "H:" .. deg(d.daily.temperature_2m_max[1]) .. "  L:" .. deg(d.daily.temperature_2m_min[1])
    -- The hours from this one on; the first is "Now", as it is.
    local hr, first = d.hourly, 1
    local this_hour = string.sub(c.time or "", 1, 13)
    for i, t in ipairs(hr.time) do if string.sub(t, 1, 13) == this_hour then first = i; break end end
    local rows = {}
    for i = first, math.min(first + 5, #hr.time) do
        rows[#rows + 1] = {
            t = i == first and "Now" or hour_name(hr.time[i]),
            temp = i == first and deg(c.temperature_2m) or deg(hr.temperature_2m[i]),
            ic = i == first and fact.wx_ic or wx_icon(tonumber(hr.weather_code[i]) or 3, hr.is_day[i] == 1),
        }
    end
    model.wxh = rows
    fact.wx_ok = true
end
local function wx_get()
    local url = "https://api.open-meteo.com/v1/forecast?latitude=" .. wx_where.lat .. "&longitude=" .. wx_where.lon
        .. "&current=temperature_2m,weather_code,is_day&hourly=temperature_2m,weather_code,is_day"
        .. "&daily=temperature_2m_max,temperature_2m_min&timezone=auto&forecast_days=2"
    run("curl", { "-sfL", "--max-time", "10", url }, function(out, code)
        local ok, d = pcall(json.decode, out or "")
        if code ~= 0 or not ok or type(d) ~= "table" or not d.current then
            if not fact.wx_ok then text.wx_cond = "Offline" end
            after(60000, wx_fetch)   -- no network yet (just woken up?): try again soon
            return
        end
        local shown = pcall(wx_show, d)
        if not shown then text.wx_cond = "Unavailable" end
    end)
end
wx_fetch = function()
    if wx_where.lat and wx_where.lon then
        text.wx_city = wx_where.city or "Here"
        wx_get()
        return
    end
    run("curl", { "-sfL", "--max-time", "8", "https://ipinfo.io/json" }, function(out, code)
        local ok, d = pcall(json.decode, out or "")
        if not ok or type(d) ~= "table" then d = {} end
        local lat, lon = string.match(d.loc or "", "^([%-%d%.]+),([%-%d%.]+)$")
        if code ~= 0 or not lat then
            text.wx_cond = "Offline"
            after(60000, wx_fetch)
            return
        end
        wx_where = { lat = lat, lon = lon, city = d.city }
        pcall(sys.call, "files.write", "weather.json", wx_where)
        text.wx_city = d.city or "Here"
        wx_get()
    end)
end
on("wx_refresh", function() text.wx_cond = "Updating…"; wx_fetch() end)
every(15 * 60000, wx_fetch)
wx_fetch()

-- ── the widgets: Up next · Batteries · News (the weather is above) ──
-- (In a function of its own: the file's top level is at Luau's 200 locals.)
;(function()
    -- ── Batteries: what is connected and says how full it is ──
    bats_refresh = function()
        local rows = {}
        for _, d in ipairs(bt_seen.devices or {}) do
            if d.connected and (d.battery or -1) >= 0 and #rows < 2 then
                rows[#rows + 1] = { name = string.upper(d.name or ""), pct = math.floor(d.battery * 100 + 0.5) }
            end
        end
        model.bats = rows
    end
    bats_refresh()

    -- Seconds since 1970 for a date and time in UTC (os.time reads them as local).
    local function utc(y, mo, d, h, mi, s)
        y = mo <= 2 and y - 1 or y
        local era = y // 400
        local yoe = y - era * 400
        local doy = (153 * (mo + (mo > 2 and -3 or 9)) + 2) // 5 + d - 1
        local doe = yoe * 365 + yoe // 4 - yoe // 100 + doy
        return ((era * 146097 + doe - 719468) * 86400) + h * 3600 + mi * 60 + s
    end

    -- ── Up next: an .ics feed (Google Calendar's "secret address in iCal
    -- format"), from calendar.json in the scene's folder: { "ics": ["https://…"] } ──
    local cal_cfg = sys.ask("files.read", "calendar.json", "json")
    if not cal_cfg then
        cal_cfg = { ics = {} }
        pcall(sys.call, "files.write", "calendar.json", cal_cfg)
    end
    local WD = { SU = 1, MO = 2, TU = 3, WE = 4, TH = 5, FR = 6, SA = 7 }   -- as os.date's wday
    -- An iCal time: all day (a date), UTC (…Z), or a wall time (with TZID, read as this machine's).
    local function ical_time(v)
        local y, mo, d = string.match(v, "^(%d%d%d%d)(%d%d)(%d%d)")
        if not y then return nil end
        y, mo, d = tonumber(y), tonumber(mo), tonumber(d)
        local h, mi, s = string.match(v, "T(%d%d)(%d%d)(%d%d)")
        if not h then return os.time({ year = y, month = mo, day = d, hour = 0 }), true end
        h, mi, s = tonumber(h), tonumber(mi), tonumber(s)
        if string.sub(v, -1) == "Z" then return utc(y, mo, d, h, mi, s), false end
        return os.time({ year = y, month = mo, day = d, hour = h, min = mi, sec = s }), false
    end
    local function unescape(t)
        t = string.gsub(t, "\\n", " "); t = string.gsub(t, "\\N", " ")
        return (string.gsub(t, "\\([,;\\])", "%1"))
    end
    -- Every time an event happens between a and b: the first, and its repeats
    -- (DAILY, WEEKLY with BYDAY, MONTHLY by date or by "2TU"/"-1FR", YEARLY;
    -- INTERVAL, COUNT, UNTIL, EXDATE).
    local function occurrences(ev, a, b, out)
        local len = ev.dtend and (ev.dtend - ev.start) or (ev.allday and 86400 or 3600)
        if not ev.rrule then
            if ev.start + len > a and ev.start < b then out[#out + 1] = { t = ev.start, e = ev.start + len, ev = ev } end
            return
        end
        local r = {}
        for k, v in string.gmatch(ev.rrule, "([A-Z]+)=([^;]+)") do r[k] = v end
        local freq, every = r.FREQ, tonumber(r.INTERVAL or "1") or 1
        local count = tonumber(r.COUNT or "")
        local until_t = r.UNTIL and ical_time(r.UNTIL) or math.huge
        local s0 = os.date("*t", ev.start)
        local bydays = {}
        for tok in string.gmatch(r.BYDAY or "", "[^,]+") do
            local n, wd = string.match(tok, "^([%+%-]?%d*)(%a%a)$")
            if wd and WD[wd] then bydays[#bydays + 1] = { n = tonumber(n), wd = WD[wd] } end
        end
        if freq == "WEEKLY" and #bydays == 0 then bydays[1] = { wd = s0.wday } end
        local day0 = os.time({ year = s0.year, month = s0.month, day = s0.day, hour = 12 })
        local n = 0
        -- Day by day from the first (a year or two of repeats is a few hundred steps).
        for i = 0, 3660 * 3 do
            local dt = os.date("*t", day0 + i * 86400)
            local hit = false
            if freq == "DAILY" then hit = i % every == 0
            elseif freq == "WEEKLY" then
                local monday0 = (s0.wday + 5) % 7     -- days since Monday, of the first
                local wk = (i + monday0) // 7
                if wk % every == 0 then for _, bd in ipairs(bydays) do if bd.wd == dt.wday then hit = true end end end
            elseif freq == "MONTHLY" then
                local months = (dt.year - s0.year) * 12 + dt.month - s0.month
                if months % every == 0 then
                    if #bydays > 0 then
                        local last = os.date("*t", os.time({ year = dt.year, month = dt.month + 1, day = 0, hour = 12 })).day
                        for _, bd in ipairs(bydays) do
                            if bd.wd == dt.wday then
                                local nth = (dt.day - 1) // 7 + 1
                                if not bd.n or bd.n == nth or (bd.n == -1 and dt.day + 7 > last) then hit = true end
                            end
                        end
                    else hit = dt.day == s0.day end
                end
            elseif freq == "YEARLY" then
                hit = (dt.year - s0.year) % every == 0 and dt.month == s0.month and dt.day == s0.day
            else
                break
            end
            if hit then
                local t = os.time({ year = dt.year, month = dt.month, day = dt.day, hour = s0.hour, min = s0.min, sec = s0.sec })
                if t > until_t then break end
                n += 1
                if count and n > count then break end
                if t >= b then break end
                if t + len > a and not ev.ex[t] then out[#out + 1] = { t = t, e = t + len, ev = ev } end
            end
        end
    end
    local function parse_ics(body, list)
        body = string.gsub(body, "\r\n[ \t]", ""); body = string.gsub(body, "\n[ \t]", "")
        for block in string.gmatch(body, "BEGIN:VEVENT(.-)END:VEVENT") do
            local ev = { ex = {} }
            for line in string.gmatch(block, "[^\r\n]+") do
                local key, params, val = string.match(line, "^([A-Z%-]+)([^:]*):(.*)$")
                if key == "SUMMARY" then ev.title = unescape(val)
                elseif key == "DTSTART" then ev.start, ev.allday = ical_time(val)
                elseif key == "DTEND" then ev.dtend = ical_time(val)
                elseif key == "RRULE" then ev.rrule = val
                elseif key == "RECURRENCE-ID" then ev.recur_id = ical_time(val)
                elseif key == "STATUS" then ev.status = val
                elseif key == "EXDATE" then
                    for v in string.gmatch(val, "[^,]+") do local t = ical_time(v); if t then ev.ex[t] = true end end
                end
            end
            if ev.start and ev.status ~= "CANCELLED" then list[#list + 1] = ev end
        end
    end
    local function clock(t) return os.date("%H:%M", t) end
    local function day_name(t)
        local d = os.date("*t", t)
        local now = os.date("*t")
        local today = os.time({ year = now.year, month = now.month, day = now.day, hour = 12 })
        local that = os.time({ year = d.year, month = d.month, day = d.day, hour = 12 })
        local diff = math.floor((that - today) / 86400 + 0.5)
        if diff == 0 then return "Today" elseif diff == 1 then return "Tomorrow" end
        return os.date("%a %d %b", t)
    end
    local cal_events = {}
    local function cal_show()
        local now = os.time()
        local occ = {}
        -- The month's dots: a few weeks back to two months ahead.
        local wide = {}
        for _, ev in ipairs(cal_events) do pcall(occurrences, ev, now - 40 * 86400, now + 70 * 86400, wide) end
        local days = {}
        for _, o in ipairs(wide) do
            local d = os.date("*t", o.t)
            days[d.year .. "-" .. d.month .. "-" .. d.day] = true
        end
        CAL_DAYS = days
        cal_redraw()
        -- A moved repeat (RECURRENCE-ID) replaces that one of its series.
        local moved = {}
        for _, ev in ipairs(cal_events) do if ev.recur_id then moved[ev.recur_id] = true end end
        for _, ev in ipairs(cal_events) do
            if ev.rrule then for t in pairs(moved) do ev.ex[t] = true end end
            pcall(occurrences, ev, now, now + 7 * 86400, occ)
        end
        table.sort(occ, function(x, y) return x.t < y.t end)
        if #cal_cfg.ics == 0 then
            model.upn = {}
            text.upn_empty = "Add your Google Calendar: its secret iCal link goes in ~/.local/share/lumen/island/calendar.json"
            return
        end
        -- The next three, the first with how long until it starts.
        local rows = {}
        for i = 1, math.min(3, #occ) do
            local o = occ[i]
            local when = ""
            if i == 1 then
                local mins = math.floor((o.t - now) / 60)
                if o.t <= now then when = "NOW"
                elseif mins < 60 then when = "IN " .. math.max(1, mins) .. " MIN"
                elseif mins < 24 * 60 then when = "IN " .. math.floor(mins / 60 + 0.5) .. " H" end
            end
            rows[#rows + 1] = {
                title = o.ev.title or "(no title)",
                time = day_name(o.t) .. " · " .. (o.ev.allday and "All day" or (clock(o.t) .. " – " .. clock(o.e))),
                when = when, first = i == 1,
            }
        end
        model.upn = rows
        text.upn_empty = "Nothing on this week"
    end
    local function cal_fetch()
        cal_cfg = sys.ask("files.read", "calendar.json", "json") or cal_cfg
        if type(cal_cfg.ics) == "string" then cal_cfg.ics = { cal_cfg.ics } end
        cal_cfg.ics = cal_cfg.ics or {}
        if #cal_cfg.ics == 0 then cal_show(); return end
        local got, left = {}, #cal_cfg.ics
        for _, url in ipairs(cal_cfg.ics) do
            run("curl", { "-sfL", "--max-time", "15", url }, function(out, code)
                if code == 0 and out then pcall(parse_ics, out, got) end
                left -= 1
                if left == 0 then
                    if #got > 0 or #cal_events == 0 then cal_events = got end
                    cal_show()
                end
            end)
        end
    end
    cal_fetch()
    every(15 * 60000, cal_fetch)
    every(60000, cal_show)   -- "in 12 min" keeps up

    -- ── News from Mauritius: French and English outlets, newest first ──
    local FEEDS = {
        { name = "Defimedia", url = "https://defimedia.info/rss.xml", lang = 1 },
        { name = "ION News", url = "https://www.ionnews.mu/feed/", lang = 1 },
        { name = "NewsMoris", url = "https://www.newsmoris.com/feed/", lang = 2 },
        { name = "Mauritius Times", url = "https://www.mauritiustimes.com/feed", lang = 2 },
    }
    local MONTHS = { jan = 1, feb = 2, ["fév"] = 2, fev = 2, mar = 3, apr = 4, avr = 4, may = 5, mai = 5, jun = 6, juin = 6,
        jul = 7, juil = 7, aug = 8, ["aoû"] = 8, aou = 8, sep = 9, oct = 10, nov = 11, dec = 12, ["déc"] = 12 }
    local function month_of(w)
        w = string.lower(w)
        return MONTHS[w] or MONTHS[string.sub(w, 1, 4)] or MONTHS[string.sub(w, 1, 3)]
    end
    -- "Wed, 21 Oct 2026 09:07:04 +0000" (or "mer, 21 oct. 2026 …") to seconds since 1970.
    local function rss_time(v)
        local d, mon, y, h, mi, s, sg, oh, om = string.match(v or "", "(%d+)%s+([^%s%d]+)%s+(%d%d%d%d)%s+(%d+):(%d+):?(%d*)%s*([%+%-]?)(%d?%d?)(%d?%d?)")
        if not d then return 0 end
        local m = month_of(string.gsub(mon, "%.", ""))
        if not m then return 0 end
        local t = utc(tonumber(y), m, tonumber(d), tonumber(h), tonumber(mi), tonumber(s) or 0)
        local off = ((tonumber(oh) or 0) * 3600 + (tonumber(om) or 0) * 60) * (sg == "-" and -1 or 1)
        return t - off
    end
    local function clean(t)
        t = string.gsub(t or "", "<!%[CDATA%[(.-)%]%]>", "%1")
        t = string.gsub(t, "<[^>]+>", "")
        t = string.gsub(t, "&#(%d+);", function(n) return utf8.char(tonumber(n)) end)
        t = string.gsub(t, "&#x(%x+);", function(n) return utf8.char(tonumber(n, 16)) end)
        t = string.gsub(t, "&quot;", '"'); t = string.gsub(t, "&apos;", "'"); t = string.gsub(t, "&lt;", "<"); t = string.gsub(t, "&gt;", ">")
        t = string.gsub(t, "&nbsp;", " "); t = string.gsub(t, "&amp;", "&")
        t = string.gsub(t, "%s+", " ")
        return (string.gsub(t, "^%s+", ""))
    end
    local function ago(t)
        local d = os.time() - t
        if d < 3600 then return math.max(1, d // 60) .. "m" end
        if d < 86400 then return d // 3600 .. "h" end
        return d // 86400 .. "d"
    end
    local headlines, news_at = {}, 0
    local shown = {}   -- the headlines of the list showing, for a click to find its link
    local function news_show()
        -- The whole list (as dealt), or only the French or the English outlets.
        local rows = {}
        shown = {}
        for _, h in ipairs(headlines) do
            if (fact.news_lang == 0 or fact.news_lang == h.lang) and #rows < 40 then
                rows[#rows + 1] = { title = h.title, meta = h.src .. " · " .. ago(h.t) }
                shown[#shown + 1] = h
            end
        end
        model.news = rows
        text.news_state = #headlines == 0 and "No news right now" or "Nothing in this language just now"
    end
    -- Dealt like cards: each outlet's newest, then each one's next…, so French
    -- and English sit together on every page however often each one posts.
    local function deal(list)
        local by, order = {}, {}
        for _, h in ipairs(list) do
            if not by[h.src] then by[h.src] = {}; order[#order + 1] = h.src end
            table.insert(by[h.src], h)
        end
        local out = {}
        for round = 1, 60 do
            local hand = {}
            for _, src in ipairs(order) do if by[src][round] then hand[#hand + 1] = by[src][round] end end
            if #hand == 0 then break end
            table.sort(hand, function(x, y) return x.t > y.t end)
            for _, h in ipairs(hand) do out[#out + 1] = h end
        end
        return out
    end
    local function news_fetch()
        local got, left = {}, #FEEDS
        for _, f in ipairs(FEEDS) do
            run("curl", { "-sfL", "--max-time", "12", "-A", "Mozilla/5.0 (lumen island)", f.url }, function(out, code)
                if code == 0 and out then
                    for item in string.gmatch(out, "<item[%s>](.-)</item>") do
                        local title = clean(string.match(item, "<title>(.-)</title>"))
                        local link = clean(string.match(item, "<link>(.-)</link>"))
                        local t = rss_time(string.match(item, "<pubDate>(.-)</pubDate>"))
                        if title ~= "" and link ~= "" and t > os.time() - 7 * 86400 then
                            got[#got + 1] = { title = title, link = link, t = t, src = f.name, lang = f.lang }
                        end
                    end
                end
                left -= 1
                if left == 0 then
                    if #got > 0 then
                        table.sort(got, function(x, y) return x.t > y.t end)
                        headlines, news_at = deal(got), os.time()
                    end
                    news_show()
                end
            end)
        end
    end
    on("news_open", function(i)
        local h = shown[i + 1]
        if h then run("xdg-open", { h.link }, nil, { output = false }) end
    end)
    on("news_filter", function(k) fact.news_lang = k; news_show() end)
    -- Opening the calendar (the news lives under it) with news older than ten minutes: fetch it again.
    on("fact:cal", function(open) if open and os.time() - news_at > 600 then news_fetch() end end)
    news_fetch()
    every(20 * 60000, news_fetch)
    every(60000, function() if fact.cal then news_show() end end)   -- "12m" ages
    on("cal_web", function() run("xdg-open", { "https://calendar.google.com" }, nil, { output = false }) end)
end)()

-- ── Gmail ───────────────────────────────────────────────────────────
-- scripts/gmail.py stays up beside the island: IMAP IDLE tells it the moment
-- the inbox moves, and it hands the list back as a line of JSON. The centre
-- card's Mail pane lists the inbox; a row (or a mail's banner) opens it in
-- the card's reader, where it can be answered, archived, binned or opened in
-- Gmail. Super+U opens the large view: the whole inbox on the left (j/k), the
-- mail on the right. A mail shown for a second is marked read, as Gmail does.
-- Its body comes as blocks: markdown (links are links) and pictures.
;(function()
    local GMAIL = HOME .. "/.config/lumen/shells/island/scripts/gmail.py"
    local msgs, by_uid, bodies = {}, {}, {}
    local seen_top = nil      -- the newest uid already known: only newer unread ones get a banner
    local open_uid = nil      -- the one in the reader
    local sel = 0             -- the one chosen in the large view's list (from 0)
    local unread = 0
    local helper = nil
    ws_icon("internet-mail")  -- asked now, so the first banner already has it

    local function send(t) if helper then write(helper, json.encode(t) .. "\n") end end

    local function mail_show()
        local rows = {}
        for i, m in ipairs(msgs) do
            rows[i] = { from = m.from, subj = m.subject, ago = ago_of(m.date), unread = m.unread }
        end
        model.mail = rows
        fact.mail_unread = math.max(0, unread)
    end

    -- The reader's body: a block a paragraph run, or a picture (fitted by the scene).
    local blocks_now = {}     -- what it shows, for a picture's link
    local renders = {}        -- uid → the mail as Gmail shows it (tiles, height, links), from Firefox
    local zoomed = {}         -- uid → the same, photographed finer: the focused view draws it larger
    local ZOOM = 1004 / 620   -- how much larger the focused view draws it (the card's whole width)
    local web_links = {}      -- the links of the render showing, for a click on one
    local is_html, full = {}, {}   -- uid → whether it has an HTML body; whether its blocks came with their pictures
    local gave_up = {}        -- uid → its render failed or was too slow: the island's own reader instead
    local function show_blocks(blocks)
        local rows = {}
        for _, b in ipairs(blocks or {}) do
            if b.img then
                rows[#rows + 1] = { md = "", img = true, pic = b.img, iw = b.w or 1, ih = b.h or 1, linked = (b.href or "") ~= "" }
            else
                rows[#rows + 1] = { md = b.md or "", img = false, pic = "", iw = 0, ih = 0, linked = false }
            end
        end
        model.mrb = rows
        blocks_now = blocks or {}
    end

    -- The large view shows a mail as Gmail would (Firefox's render) when there is one and `v` has not
    -- asked for the island's own reader; meanwhile, and for mails of plain text, the island's.
    local function show_body(uid)
        local r = renders[uid]
        local wants = fact.panel == "mailx" and fact.mx_web and not gave_up[uid] and is_html[uid] ~= false
        local web = wants and r ~= nil and r.tiles ~= nil
        -- Waiting for it: a quiet page, not the words flashing in first and then swapped away.
        fact.mr_web_wait = wants and not web
        fact.mr_has_web = web
        if web then
            local tiles, boxes = {}, {}
            for _, t in ipairs(r.tiles) do tiles[#tiles + 1] = { pic = t } end
            for k, l in ipairs(r.links or {}) do if k <= 150 then boxes[k] = { x = l.x, y = l.y, w = l.w, h = l.h } end end
            model.mrt = tiles
            model.mrk = boxes
            -- Its GIFs that move, played over the photograph where each sits.
            local anims = {}
            for k, a in ipairs(r.anims or {}) do
                if k <= 8 then anims[k] = { pic = a.pic, x = a.x, y = a.y, w = a.w, h = a.h, iw = a.iw, ih = a.ih } end
            end
            model.mra = anims
            web_links = r.links or {}
            fact.mr_web_h = #tiles * 600
            fact.mr_web_cut = r.cut == true
            -- Focused, and photographed finer: its first tiles sharp at the larger size.
            local z = fact.mx_focus and zoomed[uid] or nil
            local ztiles = {}
            if z and z.tiles then for _, t in ipairs(z.tiles) do ztiles[#ztiles + 1] = { pic = t } end end
            model.mrtz = ztiles
            fact.mr_zoom_ok = #ztiles > 0
            show_blocks({})
        else
            model.mrt = {}
            model.mrk = {}
            model.mra = {}
            model.mrtz = {}
            fact.mr_zoom_ok = false
            web_links = {}
            show_blocks(fact.mr_web_wait and {} or bodies[uid])
        end
    end

    local kept_unread = {}    -- uid → marked unread while open: not read again until it is opened anew
    local gone = nil          -- the last mail archived or binned, while it can still be brought back
    local gone_waiting = nil  -- …asked back before Gmail had said where it went
    local undo_seq = 0

    local function forget(uid)
        local kept = {}
        for _, m in ipairs(msgs) do if m.uid ~= uid then kept[#kept + 1] = m end end
        msgs = kept
        by_uid[uid] = nil
    end

    local function reader(uid)
        local m = by_uid[uid]
        if not m then return end
        open_uid = uid
        text.mr_from = m.from
        text.mr_addr = m.addr
        text.mr_init = string.upper(string.match(m.from, "^[^\128-\191][\128-\191]*") or "?")
        text.mr_subj = m.subject
        text.mr_when = m.date > 0 and os.date("%a ", m.date) .. tonumber(os.date("%d", m.date)) .. os.date(" %b · %H:%M", m.date) or ""
        show_body(uid)
        text.mr_note = ""
        text.mr_in = ""
        fact.mr_loading = bodies[uid] == nil
        fact.mr_rep = false
        fact.mr_seq = fact.mr_seq + 1
        fact.panel = "mailx"
        fact.expanded = true
        -- In the large view it is rendered too, as Gmail would show it (once: then it is remembered).
        local web = fact.panel == "mailx" and renders[uid] == nil and not gave_up[uid]
        if not bodies[uid] or web or (fact.panel ~= "mailx" and not full[uid]) then send({ op = "body", uid = uid, web = web }) end
        -- A render that does not come within six seconds: the island's own reader after all.
        if web then
            after(6000, function()
                if renders[uid] == nil and open_uid == uid then gave_up[uid] = true; show_body(uid) end
            end)
        end
        -- Read once it has been looked at a moment: stepping through the list with j/k does not.
        kept_unread[uid] = nil
        after(900, function()
            if open_uid == uid and fact.expanded and fact.panel == "mailx" and m.unread and not kept_unread[uid] then
                m.unread = false
                unread -= 1
                send({ op = "seen", uid = uid, v = true })
                mail_show()
            end
        end)
    end

    -- Focused, the open one is wanted photographed finer, once its usual render is there.
    -- Asked once the card has finished widening: its tiles are big, and taken into the atlas
    -- mid-way they made the transition stutter.
    local function want_zoom(uid)
        if fact.mx_focus and fact.mx_web and renders[uid] and not zoomed[uid] then
            after(450, function()
                if fact.mx_focus and open_uid == uid and not zoomed[uid] then
                    send({ op = "render", uid = uid, scale = ZOOM })
                end
            end)
        end
    end

    -- The large view: the chosen one, kept in the list and open on the right; the ones
    -- around it fetched and rendered ahead, so j/k lands on a mail that is already there.
    local function choose(i)
        fact.mr_confirm = false
        fact.mx_zoom = 1
        fact.mx_pan = 0
        if #msgs == 0 then return end
        sel = math.clamp(i, 0, #msgs - 1)
        fact.mx_sel = sel
        reader(msgs[sel + 1].uid)
        want_zoom(msgs[sel + 1].uid)
        local around = {}
        for _, k in ipairs({ sel + 2, sel + 3, sel + 4, sel }) do
            local m = msgs[k]
            if m and not renders[m.uid] then around[#around + 1] = m.uid end
        end
        if #around > 0 then send({ op = "ahead", uids = around }) end
    end

    local function act(uid, key)
        local m = by_uid[uid]
        if not m then return end
        if key == "archive" or key == "trash" then
            -- As iOS lets a mail go: its row slides away and the rest close up after it, and
            -- for a few seconds a pill offers it back (u).
            local at = 0
            for k, x in ipairs(msgs) do if x.uid == uid then at = k end end
            if at == 0 then return end
            fact.mx_leaving = at - 1
            fact.mr_confirm = false
            send({ op = key, uid = uid })
            gone = { uid = uid, was = key, m = m, at = at, mid = nil, wants_back = false }
            text.mail_undo_t = key == "trash" and "Moved to Bin" or "Archived"
            fact.mail_undo_bin = key == "trash"
            fact.mail_undo = true
            undo_seq += 1
            local mine = undo_seq
            after(6000, function() if undo_seq == mine then fact.mail_undo = false; gone = nil end end)
            local was_open = open_uid == uid
            after(220, function()
                fact.mx_leaving = -1
                if not by_uid[uid] then return end
                if m.unread then unread -= 1 end
                forget(uid)
                mail_show()
                -- In the large view the next one takes its place, as in a mail app.
                if was_open and fact.panel == "mailx" then choose(sel) end
            end)
        elseif key == "read" or key == "unread" then
            if m.unread ~= (key == "unread") then
                m.unread = key == "unread"
                unread += m.unread and 1 or -1
                send({ op = "seen", uid = uid, v = key == "read" })
                mail_show()
            end
            -- Kept unread: the moment's look (below, in `reader`) does not read it again while it stays open.
            if key == "unread" then kept_unread[uid] = true end
        elseif key == "web" then
            run("xdg-open", { m.url }, nil, { output = false })
            fact.expanded = false
        elseif key == "reply" then
            if open_uid ~= uid or fact.panel ~= "mailx" then mail_hook.open(uid) end
            fact.mr_rep = true
        end
    end
    -- A mail opened from anywhere —a row of the card's inbox, its banner—: the large view, on it.
    mail_hook.open = function(uid)
        local at = 0
        for k, m in ipairs(msgs) do if m.uid == uid then at = k end end
        if at == 0 then return end
        fact.expanded = true
        if fact.panel ~= "mailx" then
            fact.mr_rep = false
            fact.mx_focus = false
            send({ op = "warm" })
        end
        choose(at - 1)
    end
    mail_hook.act = act

    -- Undo: the mail back where it was at once, and back in Gmail's inbox as soon as Gmail
    -- has said where it went (its Message-ID finds it in the Bin, or in All Mail).
    local function bring_back()
        local g = gone
        if not g then return end
        gone = nil
        undo_seq += 1
        fact.mail_undo = false
        if not by_uid[g.uid] then
            table.insert(msgs, math.min(g.at, #msgs + 1), g.m)
            by_uid[g.uid] = g.m
            if g.m.unread then unread += 1 end
            mail_show()
        end
        if fact.panel == "mailx" and fact.expanded then choose(g.at - 1) end
        if g.mid then send({ op = "restore", mid = g.mid, was = g.was }) else g.wants_back = true; gone_waiting = g end
    end
    on("mail_undo_do", bring_back)

    -- A new mail: the pill grows into its banner, unless the card is open or
    -- notifications are muted; several at once share one, counted.
    local function announce(fresh)
        if #fresh == 0 or fact.expanded or fact.dnd then return end
        local m = fresh[1]
        show_banner({
            mail = true, uid = m.uid, id = -1, app = "Gmail", icon = "internet-mail",
            title = m.from, body = m.subject,
            actions = { { key = "archive", label = "Archive" }, { key = "read", label = "Mark as Read" }, { key = "reply", label = "Reply" } },
        })
        if #fresh > 1 then text.n_app = "Gmail  ·  " .. (#fresh - 1) .. " more" end
    end

    local function heard(line)
        local ok, d = pcall(json.decode, line or "")
        if not ok or type(d) ~= "table" then return end
        if d.t == "state" then
            fact.mail_ok = d.state == "ok"
            text.mail_state = d.state == "ok" and "Loading…" or (d.msg or "Can't reach Gmail")
            fact.mail_setup = d.state == "nocreds"
        elseif d.t == "list" then
            msgs, by_uid = d.msgs or {}, {}
            for _, m in ipairs(msgs) do by_uid[m.uid] = m end
            unread = d.unread or 0
            local top = msgs[1] and msgs[1].uid or 0
            if seen_top == nil then
                seen_top = top           -- what was there when the island started is not news
            elseif top > seen_top then
                local fresh = {}
                for _, m in ipairs(msgs) do if m.uid > seen_top and m.unread then fresh[#fresh + 1] = m end end
                seen_top = top
                announce(fresh)
            end
            text.mail_state = #msgs == 0 and "Your inbox is empty" or ""
            fact.mail_ok = true
            mail_show()
            -- The large view opened before the list had come: now there is something to show.
            if fact.panel == "mailx" and fact.expanded and open_uid == nil then choose(sel) end
        elseif d.t == "gone" then
            if gone and gone.uid == d.uid then gone.mid = d.mid end
            if gone_waiting and gone_waiting.uid == d.uid then
                send({ op = "restore", mid = d.mid, was = gone_waiting.was })
                gone_waiting = nil
            end
        elseif d.t == "body" then
            bodies[d.uid] = d.blocks
            is_html[d.uid] = d.html
            full[d.uid] = d.full
            if d.uid == open_uid then
                show_body(d.uid)
                fact.mr_loading = false
            end
        elseif d.t == "render" then
            if (d.scale or 1) > 1 then
                if not d.error then zoomed[d.uid] = d end
            elseif d.error then
                gave_up[d.uid] = true
            else
                renders[d.uid] = d
            end
            if d.uid == open_uid then
                show_body(d.uid)
                want_zoom(d.uid)
            end
        elseif d.t == "done" then
            if d.op == "reply" and d.uid == open_uid then
                fact.mr_sending = false
                text.mr_note = d.ok and d.msg or (d.msg or "Could not send")
                if d.ok then fact.mr_rep = false; text.mr_in = "" end
            elseif not d.ok then
                text.mr_note = d.msg or "Gmail said no"
                send({ op = "refresh" })     -- put back whatever was taken away too soon
            end
        end
    end

    local function start()
        helper = spawn(GMAIL, {}, heard, function()
            helper = nil
            fact.mail_ok = false
            text.mail_state = "Can't reach Gmail"
            after(30000, start)          -- it should not end; if it does, again in a while
        end, { stdin = "open" })
    end
    start()

    on("mail_open", function(i) local m = msgs[i + 1]; if m then mail_hook.open(m.uid) end end)
    -- The large view: opened on what was chosen last (the newest the first time), j/k through it.
    on("fact:panel", function(p) if p == "mailx" then send({ op = "warm" }); choose(sel) end end)
    -- l: focused, the mail fills the card, drawn larger (and finer, once Firefox has photographed it so).
    on("fact:mx_focus", function(f)
        if not f then fact.mx_zoom = 1; fact.mx_pan = 0 end
        if open_uid then
            show_body(open_uid)
            want_zoom(open_uid)
        end
    end)
    on("mailx_pick", function(i) choose(i) end)
    on("mailx_move", function(d) choose(sel + d) end)
    -- v: Gmail's look, or the island's own reader.
    on("fact:mx_web", function() if open_uid then show_body(open_uid) end end)
    on("mail_wlink", function(i)
        local l = web_links[i + 1]
        if l and (string.match(l.href, "^https?://") or string.match(l.href, "^mailto:")) then
            run("xdg-open", { l.href }, nil, { output = false })
            fact.expanded = false
        end
    end)
    -- A link in a mail, or a picture that is one: in the browser.
    on("link", function(url)
        if string.match(url, "^https?://") or string.match(url, "^mailto:") then
            run("xdg-open", { url }, nil, { output = false })
            fact.expanded = false
        end
    end)
    on("mail_img", function(i)
        local b = blocks_now[i + 1]
        if b and (b.href or "") ~= "" then
            run("xdg-open", { b.href }, nil, { output = false })
            fact.expanded = false
        end
    end)
    on("mail_arch", function(i) local m = msgs[i + 1]; if m then act(m.uid, "archive") end end)
    on("mail_refresh", function() send({ op = "refresh" }) end)
    -- The reader's buttons: 0 reply · 1 unread · 2 archive · 3 bin · 4 in Gmail.
    on("mail_do", function(k)
        if open_uid then act(open_uid, ({ "reply", "unread", "archive", "trash", "web" })[k + 1]) end
    end)
    on("mail_send", function()
        local body = string.gsub(text.mr_in or "", "^%s+", "")
        if body == "" or not open_uid or fact.mr_sending then return end
        fact.mr_sending = true
        text.mr_note = "Sending…"
        send({ op = "reply", uid = open_uid, text = body })
    end)
    every(60000, function() if fact.expanded and fact.panel == "home" then mail_show() end end)   -- "12m" ages
end)()

-- ── WhatsApp ────────────────────────────────────────────────────────
-- scripts/whatsapp (Go, whatsmeow) is a linked device of the phone's account,
-- as WhatsApp Web is, built to ~/.local/share/lumen/whatsapp/lumen-wa. It keeps
-- the messages itself and hands the chats and a chat's messages back as lines
-- of JSON. Super+W opens the view: the chats down the left (j/k), the chosen one
-- on the right; what comes in while it is not looked at rides a banner.
--
-- Kept cheap on purpose: the renderer is told only what changed, record by
-- record, so nothing here moves records around that did not change. The list
-- holds only the rows in sight (a window over the chats); a chat holds its
-- newest 40 messages and grows at its end as they come, and backwards only as
-- it is scrolled up; a message sent shows at once and is put right in place.
;(function()
    local WA = sys.ask("env", "LUMEN_WA") or ""   -- another helper in its place (a fake one, to try the view)
    if WA == "" then WA = HOME .. "/.local/share/lumen/whatsapp/lumen-wa" end
    local ROWS, SEEN, ABOVE = 16, 9, 3   -- the list's records, how many are wholly in sight, how many kept above them (to glide over)
    local FIRST, MORE, MAXROWS = 40, 30, 120   -- a chat opens on its newest 40, grows 30 at a time, up to 120 rows
    local chats, shown = {}, {}   -- every chat, and the ones the search lets through
    local sel, off = 0, 0         -- the chosen one, and the first in sight (both from 0, in `shown`)
    local open_jid = nil          -- the chat on the right
    local msgs = {}               -- its messages, oldest first: what the helper has handed over
    local start = 1               -- the first of them drawn
    local cache = {}              -- jid → its messages, so going back to one shows it at once
    local done_back = {}          -- jid → the helper has nothing older
    local loading = false         -- older ones asked for
    local rows_of = {}            -- the rows showing → their message (a press finds it)
    local nrows = 0               -- how many rows show
    local typing = {}             -- jid → while they write
    local want_open = {}          -- media id → opened once it has come
    local ql_id = nil             -- the picture Quick Look shows (its whole file replaces the small one when it comes)
    local helper = nil
    local wa_state = "connecting"
    local paired_asked = false    -- a code asked for since the view opened
    local player = nil            -- a voice note playing
    local here = false
    local tmp_n = 0
    local ICON = "com.github.eneshecan.WhatsAppForLinux"   -- WhiteSur's WhatsApp
    ws_icon(ICON)             -- asked now, so the first banner already has it

    local function send(t) if helper then write(helper, json.encode(t) .. "\n") end end
    local function looking() return fact.expanded and fact.panel == "wa" end

    -- The first letter of the first and the last word ("Ana Sofía Pérez" → "AP").
    local function initials(name)
        local words = {}
        for w in string.gmatch(name or "", "%S+") do words[#words + 1] = w end
        local function first(w) return string.upper(string.match(w or "", "^[^\128-\191][\128-\191]*") or "") end
        if #words == 0 or string.match(words[1], "^%+") then return "#" end
        local a = first(words[1])
        local b = #words > 1 and first(words[#words]) or ""
        if not string.match(b, "^%a$") then b = "" end
        return a .. b
    end
    local function midnight()
        local t = os.date("*t")
        return os.time({ year = t.year, month = t.month, day = t.day, hour = 0 })
    end
    -- As WhatsApp says when: the time today, then Yesterday, the weekday, the date.
    local function when(t)
        if not t or t == 0 then return "" end
        local m0 = midnight()
        if t >= m0 then return os.date("%H:%M", t) end
        if t >= m0 - 86400 then return "Yesterday" end
        if t >= m0 - 6 * 86400 then return os.date("%A", t) end
        return os.date("%d/%m/%y", t)
    end
    local function day_of(t)
        local m0 = midnight()
        if t >= m0 then return "Today" end
        if t >= m0 - 86400 then return "Yesterday" end
        if t >= m0 - 6 * 86400 then return os.date("%A", t) end
        return os.date("%A ", t) .. tonumber(os.date("%d", t)) .. os.date(" %B", t)
    end
    local function matches(name, q)
        if q == "" then return true end
        name = string.lower(name)
        for w in string.gmatch(string.lower(q), "%S+") do
            if not string.find(name, w, 1, true) then return false end
        end
        return true
    end

    -- ── the list: only the rows in sight ──
    local unread_all = 0          -- what the helper counts unread, everywhere
    local function list_show()
        off = math.clamp(off, 0, math.max(0, #shown - SEEN))
        local first = math.max(0, off - ABOVE)
        local rows = {}
        -- The chat being read has nothing unread, even in the moment before it is marked read.
        local reading = looking() and open_jid or nil
        local hidden = 0
        for _, c in ipairs(chats) do if c.jid == reading then hidden = c.unread end end
        fact.wa_unread = math.max(0, unread_all - hidden)
        for i = first + 1, math.min(first + ROWS, #shown) do
            local c = shown[i]
            local unread = c.jid == reading and 0 or c.unread
            rows[#rows + 1] = {
                name = c.name, last = c.last, ago = when(c.ts), unread = unread,
                badge = unread > 99 and "99+" or tostring(unread), muted = c.muted, pinned = c.pinned, group = c.group,
                init = initials(c.name), pic = c.pic or "", typing = typing[c.jid] == true,
            }
        end
        model.wac = rows
        fact.wa_first = first
        fact.wa_off = off
        fact.wa_total = #shown
    end
    local function filter()
        local q = text.wa_find or ""
        shown = {}
        for _, c in ipairs(chats) do
            if #shown < 60 and matches(c.name, q) then shown[#shown + 1] = c end
        end
        fact.wa_filtered = q ~= ""
        text.wa_list_t = #chats == 0 and (wa_state == "ok" and "Your chats will show up here as they sync" or "Connecting…")
            or "No chat by that name"
    end
    local function keep_in_view()
        if sel < off then off = sel end
        if sel > off + SEEN - 1 then off = sel - SEEN + 1 end
    end

    -- ── the chat: its header, and its messages as rows ──
    local function header()
        local c = nil
        for _, x in ipairs(chats) do if x.jid == open_jid then c = x end end
        fact.wa_open = c ~= nil
        if not c then return end
        text.wa_name = c.name
        text.wa_init = initials(c.name)
        text.wa_pic_path = c.pic or ""
        -- Typing shows as iOS's bubble in the chat; the corner says only what just happened (Copied…).
        fact.wa_typing_in = typing[c.jid] == true
        text.wa_sub = ""
        fact.wa_has_sub = false
    end

    local function row_of(m, img, from, tail)
        local dw, dh = 0, 0
        if img then
            local w, h = m.w or 0, m.h or 0
            if w <= 0 or h <= 0 then w, h = (m.kind == "sticker" and 1 or 4), (m.kind == "sticker" and 1 or 3) end
            local s = math.min(280 / w, 280 / h)
            dw, dh = math.max(96, math.floor(w * s)), math.max(64, math.floor(h * s))
            if m.kind == "sticker" then dw, dh = math.min(dw, 160), math.min(dh, 160) end
        end
        local body = m.text or ""
        local file = false
        if m.kind == "audio" then body = "▶  " .. body; file = true
        elseif m.kind == "doc" then body = "📄  " .. (string.match(body, "^[^\n]*") or ""); file = true
        elseif m.kind == "video" and not img then body = "🎥  Video" .. (body ~= "" and (" · " .. body) or ""); file = true
        elseif m.kind == "image" and not img then body = "📷  Photo" .. (body ~= "" and (" · " .. body) or ""); file = true
        elseif m.kind == "sticker" then body = img and "" or "Sticker"
        elseif m.kind == "video" and img and body == "" then body = "🎥 Video" end
        local n = utf8.len(body)
        return {
            text = body, has_text = body ~= "", me = m.me,
            long = n == nil or n > 50 or string.find(body, "\n", 1, true) ~= nil,
            from = from, has_from = from ~= "", time = os.date("%H:%M", m.ts), tail = tail,
            faint = m.kind == "deleted" or m.failed == true, img = img, sticker = m.kind == "sticker", pic = img and m.media or "", dw = dw, dh = dh, file = file,
            has_q = (m.qtext or "") ~= "", qfrom = m.qfrom or "", qtext = m.qtext or "",
            -- What dragging it out gives: the file itself, once it is here whole.
            full = ((m.media or "") ~= "" and not string.find(m.media, "%-t%.jpg$")) and m.media or "",
        }
    end

    -- A chat opening (or every row moving to another message: older ones put in above): its rows take their heights at once while their words are measured,
    -- and only then on their springs (which slide a new message in).
    local snap_n = 0
    local function snap()
        snap_n += 1
        local n = snap_n
        fact.wa_snap = true
        after(350, function() if snap_n == n then fact.wa_snap = false end end)
    end

    -- Every row from `start` on. Rows already there come out the same, so only a
    -- message that changed (or one more at the end) reaches the renderer.
    local function msgs_show()
        local pics_left = 14    -- the newest pictures only: the atlas has room for so many
        local drawn = {}
        for i = #msgs, start, -1 do
            local m = msgs[i]
            if pics_left > 0 and (m.kind == "image" or m.kind == "sticker" or m.kind == "video") and (m.media or "") ~= "" then
                drawn[i] = true
                pics_left -= 1
            end
        end
        local rows = {}
        rows_of = {}
        -- A run: messages from the same side (and person) within three minutes, on the same day.
        local function same_run(a, b)
            return a and b and a.me == b.me and (a.from or "") == (b.from or "") and math.abs(b.ts - a.ts) < 180
                and os.date("%Y%m%d", a.ts) == os.date("%Y%m%d", b.ts)
        end
        local last_me = nil
        for i = #msgs, start, -1 do
            if msgs[i].me then last_me = i; break end
        end
        local last_day = nil
        for i = start, #msgs do
            local m = msgs[i]
            local d = os.date("%Y%m%d", m.ts)
            if d ~= last_day then
                last_day = d
                rows[#rows + 1] = { text = day_of(m.ts), time = os.date("%H:%M", m.ts), day = true }
                rows_of[#rows] = false
            end
            local first = not same_run(msgs[i - 1], m) or i == start
            local from = (first and not m.me and (m.from or "") ~= "") and m.from or ""
            local r = row_of(m, drawn[i] == true, from, not same_run(m, msgs[i + 1]))
            -- Under the last one sent, as iMessage says it.
            if i == last_me then
                r.status = m.failed and "Not delivered" or (m.st >= 3 and "Read" or (m.st == 2 and "Delivered" or (m.st == 1 and "Sent" or "Sending…")))
                r.has_status = true
                r.tail = true
            end
            rows[#rows + 1] = r
            rows_of[#rows] = m
        end
        -- A long live conversation: past the cap, the oldest go (the rows shift, once in a long while).
        if #rows > MAXROWS then
            start = math.min(#msgs, start + MORE)
            snap()
            local was_rows = #rows
            msgs_show()
            if fact.wa_cur >= 0 then
                local c = fact.wa_cur - (was_rows - nrows)
                fact.wa_cur = c >= 0 and c or -1
            end
            return
        end
        nrows = #rows
        model.wam = rows
    end

    local function read_soon(jid)
        after(900, function()
            if looking() and open_jid == jid then
                for _, c in ipairs(chats) do
                    if c.jid == jid and c.unread > 0 then
                        c.unread = 0
                        send({ op = "read", jid = jid })
                        list_show()
                    end
                end
            end
        end)
    end

    local quote = nil         -- the message being answered (r)
    local function unquote()
        quote = nil
        fact.wa_quote = false
    end

    local att_clear   -- (below) files waiting are for the chat they were put in

    local function open_chat(jid)
        if jid ~= open_jid and att_clear then att_clear() end
        snap()
        fact.wa_cur = -1
        unquote()
        open_jid = jid
        cache[jid] = cache[jid] or {}
        msgs = cache[jid]
        start = math.max(1, #msgs - FIRST + 1)
        loading = false
        msgs_show()
        fact.wa_seq = fact.wa_seq + 1
        text.wa_in = ""
        fact.wa_has_in = false
        send({ op = "open", jid = jid })
    end

    local function choose(i)
        if #shown == 0 then
            open_jid = nil
            fact.wa_open = false
            model.wam = {}
            return
        end
        sel = math.clamp(i, 0, #shown - 1)
        fact.wa_sel = sel
        keep_in_view()
        list_show()
        local c = shown[sel + 1]
        if c.jid ~= open_jid then open_chat(c.jid) end
        header()
        if c.unread > 0 then read_soon(c.jid) end
    end

    local function set_here(on)
        if on ~= here and wa_state == "ok" then
            here = on
            send({ op = "here", on = on })
        end
    end

    local function show_state(s, msg)
        wa_state = s
        fact.wa_state = s
        fact.wa_linked = s ~= "pair" and s ~= "qr"
        text.wa_msg = msg or ""
        if s == "pair" and looking() and not paired_asked then
            paired_asked = true
            send({ op = "pair" })
        end
        filter()
        list_show()
    end

    -- Something came in while it was not looked at: the pill grows into its banner.
    local function announce(d)
        if fact.expanded or fact.dnd or d.muted then return end
        if (d.msg.ts or 0) < os.time() - 120 then return end   -- what queued up while offline is not news
        local c = nil
        for _, x in ipairs(chats) do if x.jid == d.jid then c = x end end
        local body = d.msg.text or ""
        if body == "" then body = ({ image = "📷 Photo", video = "🎥 Video", sticker = "Sticker" })[d.msg.kind] or "" end
        show_banner({
            wa = true, jid = d.jid, id = -1, app = "WhatsApp", icon = ICON,
            image = c and c.pic or "", title = d.name ~= "" and d.name or (c and c.name or "WhatsApp"), body = body,
            actions = { { key = "reply", label = "Reply" }, { key = "read", label = "Mark as Read" } },
        })
    end

    local function open_file(path, kind)
        if kind == "audio" then
            if player then kill(player); player = nil end
            player = spawn("mpv", { "--no-video", "--really-quiet", path }, function() end, function() player = nil end)
        else
            run("xdg-open", { path }, nil, { output = false })
            fact.expanded = false
        end
    end

    -- One message more, or one changed (delivered, read, an edit, the real one for the one sent).
    local function put(jid, m, tmp)
        local list = cache[jid]
        if not list then return end
        local key = tmp ~= nil and tmp ~= "" and tmp or m.id
        for i = #list, 1, -1 do
            if list[i].id == key or list[i].id == m.id then list[i] = m; return false end
        end
        list[#list + 1] = m
        return true
    end

    local function heard(line)
        local ok, d = pcall(json.decode, line or "")
        if not ok or type(d) ~= "table" then return end
        if d.t == "state" then
            if d.state == "qr" and d.qr then text.wa_qr_path = d.qr end
            show_state(d.state, d.msg)
            if d.state == "ok" and looking() then here = false; set_here(true) end
        elseif d.t == "chats" then
            chats = d.chats or {}
            unread_all = d.unread or 0
            filter()
            -- The chosen one stays chosen where it went (a new message takes its chat to the top).
            local found = false
            if open_jid then
                for i, c in ipairs(shown) do
                    if c.jid == open_jid then sel = i - 1; found = true end
                end
            end
            if found then
                fact.wa_sel = sel
                if looking() then keep_in_view() end
                list_show()
                header()
            else
                choose(sel)       -- also the first time: the newest chat ready before the view is opened
            end
        elseif d.t == "msgs" then
            -- What the helper keeps can be newer than the cache (messages sent from the phone).
            local had = cache[d.jid]
            cache[d.jid] = d.msgs or {}
            if had then
                for _, m in ipairs(had) do
                    if string.sub(m.id, 1, 4) == "tmp-" then put(d.jid, m) end   -- still on its way
                end
            end
            if d.jid == open_jid then
                local was = #msgs
                msgs = cache[d.jid]
                if was == 0 or #msgs < start then start = math.max(1, #msgs - FIRST + 1) end
                msgs_show()
                if was == 0 then snap() end
            end
        elseif d.t == "older" then
            loading = false
            local older = d.msgs or {}
            if #older < 60 then done_back[d.jid] = true end
            if d.jid == open_jid and #older > 0 then
                local was_rows = nrows
                local list = {}
                for _, m in ipairs(older) do list[#list + 1] = m end
                for _, m in ipairs(msgs) do list[#list + 1] = m end
                start = start + #older
                cache[d.jid] = list
                msgs = list
                start = math.max(1, start - MORE)
                snap()
                msgs_show()
                if fact.wa_cur >= 0 then fact.wa_cur = fact.wa_cur + nrows - was_rows end
            end
        elseif d.t == "msg" then
            local more = put(d.jid, d.msg, d.tmp)
            if d.jid == open_jid then
                msgs = cache[d.jid] or msgs
                msgs_show()
                -- One more at the bottom: the chat follows it down if it was there (or it is ours).
                if more then
                    if d.msg.me then fact.wa_mine = fact.wa_mine + 1 else fact.wa_tail = fact.wa_tail + 1 end
                end
                if d.live and not d.msg.me then read_soon(d.jid) end
            end
            if d.live and not d.msg.me and not (looking() and open_jid == d.jid) then announce(d) end
            if typing[d.jid] and not d.msg.me then typing[d.jid] = nil; list_show(); header() end
        elseif d.t == "media" then
            local list = cache[d.jid]
            if list and (d.path or "") ~= "" then
                for _, m in ipairs(list) do if m.id == d.id then m.media = d.path end end
            end
            if d.jid == open_jid then msgs_show() end
            if ql_id == d.id and (d.path or "") ~= "" then text.wa_ql_path = d.path end
            if want_open[d.id] then
                local kind = want_open[d.id]
                want_open[d.id] = nil
                if (d.path or "") ~= "" then open_file(d.path, kind) end
            end
        elseif d.t == "typing" then
            if (typing[d.jid] == true) ~= (d.on == true) then
                typing[d.jid] = d.on or nil
                if d.on then after(9000, function() if typing[d.jid] then typing[d.jid] = nil; list_show(); header() end end) end
                list_show()
                if d.jid == open_jid then header() end
            end
        elseif d.t == "done" then
            if not d.ok then
                local list = cache[d.jid]
                if list then
                    for _, m in ipairs(list) do if m.id == d.tmp then m.failed = true end end
                end
                if d.jid == open_jid then msgs_show() end
            end
        end
    end

    local function start_helper()
        run("test", { "-x", WA }, function(_, code)
            if code ~= 0 then
                show_state("offline", "Build the helper first (scripts/whatsapp)")
                text.wa_list_t = "The WhatsApp helper isn't built yet"
                return
            end
            helper = spawn(WA, {}, heard, function()
                helper = nil
                here = false
                after(wa_state == "pair" and 3000 or 30000, start_helper)   -- logged out: back at once, to be linked again
                show_state("offline", "Can't reach WhatsApp")
            end, { stdin = "open" })
        end)
    end
    start_helper()

    on("wa_pick", function(i) choose(math.max(0, off - ABOVE) + i) end)
    on("wa_move", function(dlt) choose(sel + dlt) end)
    on("wa_wheel", function(w)
        off = off + (w > 0 and -2 or 2)
        list_show()
    end)
    -- Scrolled up to the top of what is drawn: 30 older ones (from the helper once all it sent is drawn).
    on("wa_older", function()
        if loading or not open_jid or nrows > MAXROWS - MORE - 10 then return end   -- as far back as a chat goes here
        if start > 1 then
            local was_rows = nrows
            start = math.max(1, start - MORE)
            snap()
            msgs_show()
            if fact.wa_cur >= 0 then fact.wa_cur = fact.wa_cur + nrows - was_rows end
        elseif not done_back[open_jid] and msgs[1] then
            loading = true
            send({ op = "older", jid = open_jid, before = msgs[1].id })
        end
    end)
    on("wa_pair", function() paired_asked = true; send({ op = "pair" }) end)
    on("wa_find_clear", function()
        text.wa_find = ""
        filter()
        choose(0)
    end)
    on("text:wa_find", function()
        filter()
        off = 0
        choose(0)
    end)
    on("fact:panel", function(p)
        if p == "wa" then
            paired_asked = false
            if wa_state == "pair" then paired_asked = true; send({ op = "pair" }) end
            choose(sel)
            set_here(fact.expanded)
        else
            set_here(false)
        end
    end)
    on("fact:expanded", function(e)
        set_here(e and fact.panel == "wa")
        list_show()   -- the open chat's unread hidden only while it is read
        if not e then fact.wa_typing = false; fact.wa_search = false end
        if e and fact.panel == "wa" and open_jid then read_soon(open_jid) end
    end)

    -- Writing: they see "typing…" while there is something in the field, told once
    -- when it starts and once when it stops (five seconds without a key, or sent).
    local typed_at, told_jid = 0, nil
    on("text:wa_in", function(v)
        local has = (v or "") ~= ""
        if fact.wa_has_in ~= has then fact.wa_has_in = has end
        if has and open_jid then
            typed_at = os.time()
            if told_jid ~= open_jid then
                told_jid = open_jid
                send({ op = "typing", jid = open_jid, on = true })
            end
        elseif told_jid then
            send({ op = "typing", jid = told_jid, on = false })
            told_jid = nil
        end
    end)
    every(2000, function()
        if told_jid and os.time() - typed_at >= 5 then
            send({ op = "typing", jid = told_jid, on = false })
            told_jid = nil
        end
    end)
    -- Sent: it shows at once ("Sending…" under it), and the helper's answer takes its place.
    -- ── files: pasted, dropped, sent ──
    local PASTE = HOME .. "/.cache/lumen/whatsapp/paste"
    run("mkdir", { "-p", PASTE }, nil, { output = false })
    local staged = {}         -- { path, kind, name, size, w, h }, in the order they came
    local KIND_OF = { jpg = "image", jpeg = "image", png = "image", gif = "image", mp4 = "video", ogg = "audio", mp3 = "audio", m4a = "audio", aac = "audio" }
    local LABEL = { image = "Photo", video = "Video", audio = "Audio", doc = "Document" }
    local function human(n)
        if n >= 1048576 then return string.format("%.1f MB", n / 1048576) end
        if n >= 1024 then return string.format("%d KB", math.floor(n / 1024 + 0.5)) end
        return n .. " B"
    end
    local function att_show()
        fact.wa_att = #staged > 0
        local f = staged[1]
        if not f then return end
        fact.wa_att_kind = ({ image = 0, video = 1, audio = 2 })[f.kind] or 3
        text.wa_att_path = f.kind == "image" and f.path or ""
        if #staged == 1 then
            text.wa_att_name = f.name
            text.wa_att_sub = LABEL[f.kind] .. " · " .. human(f.size)
        else
            local all_pics, total, names = true, 0, {}
            for _, x in ipairs(staged) do
                all_pics = all_pics and x.kind == "image"
                total += x.size
                names[#names + 1] = x.name
            end
            text.wa_att_name = #staged .. (all_pics and " photos" or " files")
            text.wa_att_sub = human(total) .. " · " .. table.concat(names, ", ")
        end
    end
    att_clear = function()
        if #staged == 0 then return end
        staged = {}
        att_show()
    end
    on("wa_att_clear", att_clear)
    -- A file to send: what it is (by its name), how big, and a picture's size (so its bubble is right at once).
    local function stage(path, name)
        if not open_jid or path == "" then return end
        run("stat", { "-L", "-c", "%s|%F", path }, function(out, code)
            local size, ftype = string.match(out or "", "^(%d+)|([^\n]*)")
            if code ~= 0 or not size or ftype ~= "regular file" and ftype ~= "regular empty file" then
                text.wa_sub = "Only files can be sent"
                fact.wa_has_sub = true
                after(1800, header)
                return
            end
            for _, x in ipairs(staged) do if x.path == path then return end end
            local ext = string.lower(string.match(path, "%.([^./]+)$") or "")
            local f = { path = path, kind = KIND_OF[ext] or "doc", name = name or string.match(path, "[^/]+$") or path, size = tonumber(size), w = 0, h = 0 }
            if #staged >= 10 then return end
            staged[#staged + 1] = f
            att_show()
            fact.wa_typing = true   -- the caption is written next
            if f.kind == "image" then
                run("magick", { "identify", "-format", "%w %h", path .. "[0]" }, function(o)
                    local w, h = string.match(o or "", "^(%d+) (%d+)")
                    f.w, f.h = tonumber(w) or 0, tonumber(h) or 0
                end)
            end
        end)
    end
    -- `file:///a%20b` → `/a b`.
    local function path_of(uri)
        local p = string.gsub(uri, "^file://[^/]*", "")
        return (string.gsub(p, "%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end))
    end
    -- What was dropped or copied as a list of addresses: files are put in; a picture on the web is fetched first.
    local function take_uris(list)
        for uri in string.gmatch(list or "", "[^\r\n]+") do
            if string.sub(uri, 1, 1) ~= "#" then
                if string.match(uri, "^file:") then
                    stage(path_of(uri))
                elseif string.match(uri, "^/") then
                    stage(uri)
                elseif string.match(uri, "^https?://") then
                    local name = string.match(uri, "([^/?#]+)[?#]?[^/]*$") or "download"
                    tmp_n += 1
                    local dest = PASTE .. "/" .. tmp_n .. "-" .. string.gsub(name, "[^%w%.%-_]", "_")
                    run("curl", { "-sfL", "--max-time", "60", "--max-filesize", "104857600", "-o", dest, uri }, function(_, code)
                        if code == 0 then stage(dest, name) end
                    end)
                end
            end
        end
    end
    -- Ctrl+V the field left alone: a picture on the clipboard, files copied, or (outside the field) words.
    on("wa_paste", function()
        if not open_jid then return end
        run("wl-paste", { "-l" }, function(out, code)
            if code ~= 0 then return end
            local has, pic = {}, nil
            for t in string.gmatch(out or "", "[^\n]+") do has[t] = true end
            for _, t in ipairs({ "image/png", "image/jpeg", "image/gif", "image/webp", "image/bmp" }) do
                if has[t] and not pic then pic = t end
            end
            if has["text/uri-list"] then
                run("wl-paste", { "-n", "-t", "text/uri-list" }, function(list) take_uris(list) end)
            elseif pic then
                tmp_n += 1
                local ext = ({ ["image/jpeg"] = "jpg", ["image/gif"] = "gif" })[pic] or "png"
                local dest = PASTE .. "/pasted-" .. os.time() .. "-" .. tmp_n .. "." .. ext
                -- webp and bmp are turned into a PNG (WhatsApp takes JPEG and PNG pictures).
                local cmd = (pic == "image/webp" or pic == "image/bmp") and 'wl-paste -t "$1" | magick - "png:$2"' or 'wl-paste -t "$1" > "$2"'
                run("sh", { "-c", cmd, "sh", pic, dest }, function(_, c)
                    if c == 0 then stage(dest, "Pasted picture") end
                end)
            elseif not fact.wa_typing then
                run("wl-paste", { "-n" }, function(words, c)
                    if c ~= 0 or (words or "") == "" then return end
                    text.wa_in = (text.wa_in or "") .. string.gsub(words, "[\r\n\t]+", " ")
                    fact.wa_has_in = true
                    fact.wa_typing = true
                end)
            end
        end)
    end)
    on("drop:wa_drop_z", function(data, mime)
        if mime == "text/uri-list" or string.match(data or "", "^file://") then
            take_uris(data)
        elseif (data or "") ~= "" then
            text.wa_in = (text.wa_in or "") .. string.gsub(data, "[\r\n\t]+", " ")
            fact.wa_has_in = true
            fact.wa_typing = true
        end
    end)
    -- The pointer over a picture or file: fetched whole now, so opening it is instant and it can be dragged out.
    local prefetched = {}
    on("wa_prefetch", function(i)
        local m = rows_of[i + 1]
        if not m or not open_jid or prefetched[m.id] or string.sub(m.id, 1, 4) == "tmp-" then return end
        if m.kind ~= "image" and m.kind ~= "video" and m.kind ~= "doc" and m.kind ~= "audio" and m.kind ~= "sticker" then return end
        local have = m.media or ""
        if have ~= "" and not string.find(have, "%-t%.jpg$") then return end
        prefetched[m.id] = true
        send({ op = "media", jid = open_jid, id = m.id })
    end)

    local function send_files(caption)
        local cap_on = nil      -- which one carries the caption: the first that can (a voice note can't)
        for i, f in ipairs(staged) do if not cap_on and f.kind ~= "audio" then cap_on = i end end
        local q = quote
        for i, f in ipairs(staged) do
            tmp_n += 1
            local tmp = "tmp-" .. tmp_n
            local cap = i == cap_on and caption or ""
            local shown_text = cap
            if f.kind == "doc" then shown_text = f.name .. (cap ~= "" and ("\n" .. cap) or "")
            elseif f.kind == "audio" then shown_text = "Audio" end
            msgs[#msgs + 1] = { id = tmp, me = true, from = "", text = shown_text, ts = os.time(), kind = f.kind,
                media = f.kind == "image" and f.path or "", w = f.w, h = f.h, st = 0,
                qfrom = (i == 1 and q) and q.from or "", qtext = (i == 1 and q) and q.text or "" }
            send({ op = "file", jid = open_jid, path = f.path, caption = cap, tmp = tmp, quote = (i == 1 and q) and q.id or "" })
        end
        staged = {}
        att_show()
        return cap_on ~= nil
    end

    on("wa_send", function()
        local body = string.gsub(string.gsub(text.wa_in or "", "^%s+", ""), "%s+$", "")
        if not open_jid then return end
        if #staged > 0 then
            cache[open_jid] = cache[open_jid] or msgs
            msgs = cache[open_jid]
            local captioned = send_files(body)
            text.wa_in = ""
            fact.wa_has_in = false
            told_jid = nil
            unquote()
            msgs_show()
            fact.wa_mine = fact.wa_mine + 1
            if captioned or body == "" then return end
            text.wa_in = body       -- only voice notes went: the words go as a message of their own
        end
        if body == "" then return end
        tmp_n += 1
        local tmp = "tmp-" .. tmp_n
        cache[open_jid] = cache[open_jid] or msgs
        msgs = cache[open_jid]
        local q = quote
        msgs[#msgs + 1] = { id = tmp, me = true, from = "", text = body, ts = os.time(), kind = "text", media = "", w = 0, h = 0, st = 0,
            qfrom = q and q.from or "", qtext = q and q.text or "" }
        text.wa_in = ""
        fact.wa_has_in = false    -- written here, the field does not report it back
        told_jid = nil
        unquote()
        msgs_show()
        fact.wa_mine = fact.wa_mine + 1
        send({ op = "send", jid = open_jid, text = body, tmp = tmp, quote = q and q.id or "" })
    end)
    -- A picture (whole once it has come), a voice note (played here), a video or a file.
    local function open_media(m)
        if not m or not open_jid then return end
        local have = m.media or ""
        if have ~= "" and not string.find(have, "%-t%.jpg$") then
            open_file(have, m.kind)
        else
            want_open[m.id] = m.kind
            send({ op = "media", jid = open_jid, id = m.id })
        end
    end
    on("wa_media", function(i) open_media(rows_of[i + 1]) end)

    -- Space: Quick Look. The picture whole once it is here (its small one meanwhile), fitted into 992 × 600;
    -- j/k while it shows step the cursor, and a picture it lands on takes its place. A video plays instead.
    local function look(m)
        if not m or not open_jid then return false end
        if m.kind == "video" then open_media(m); return true end
        if m.kind ~= "image" and m.kind ~= "sticker" then return false end
        local have = m.media or ""
        local whole = have ~= "" and not string.find(have, "%-t%.jpg$")
        if not whole then
            send({ op = "media", jid = open_jid, id = m.id })
        end
        local w, h = m.w or 0, m.h or 0
        if w <= 0 or h <= 0 then w, h = 4, 3 end
        local k = math.min(992 / w, 600 / h)
        fact.wa_qlw = math.floor(w * k + 0.5)
        fact.wa_qlh = math.floor(h * k + 0.5)
        text.wa_ql_path = have
        local who = m.me and "You" or ((m.from or "") ~= "" and m.from or text.wa_name)
        text.wa_ql_cap = who .. " · " .. os.date("%H:%M", m.ts) .. (((m.text or "") ~= "" and m.kind == "image") and (" · " .. string.match(m.text, "^[^\n]*")) or "")
        ql_id = m.id
        fact.wa_ql = true
        return true
    end
    on("wa_look", function()
        local i = fact.wa_hov >= 0 and fact.wa_hov or fact.wa_cur
        look(rows_of[i + 1])
    end)
    on("fact:wa_cur", function(c)
        if not fact.wa_ql then return end
        local m = rows_of[(c or -1) + 1]
        if m and (m.kind == "image" or m.kind == "sticker") then look(m) end
    end)
    on("fact:wa_ql", function(v) if not v then ql_id = nil end end)

    -- ── Vim's keys over the view ──
    -- j/k in the chat, with a count: the cursor a row at a time (each row works out its step),
    -- from the newest when there is none yet.
    on("wa_cmove", function(n)
        if not open_jid or nrows == 0 then return end
        local steps = math.abs(n)
        if fact.wa_cur < 0 then
            emit("wa_last")
            steps -= 1
        end
        for i = 1, math.min(steps, 60) do
            after(i * 18, function() emit(n > 0 and "wa_j" or "wa_k") end)
        end
    end)
    -- The list: H M L (top, middle, bottom of what is in sight), n N (the next / previous unread), zz.
    on("wa_jump", function(code)
        if #shown == 0 then return end
        local last = math.min(#shown, off + SEEN) - 1
        if code == 0 then choose(off)
        elseif code == 1 then choose(math.floor((off + last) / 2))
        elseif code == 2 then choose(last)
        elseif code == 3 or code == 4 then
            local step = code == 3 and 1 or -1
            local i = sel + step
            while i >= 0 and i < #shown do
                if shown[i + 1].unread > 0 then choose(i); return end
                i += step
            end
        elseif code == 5 then
            off = sel - math.floor(SEEN / 2)
            list_show()
        end
    end)
    local function under_cursor()
        local m = rows_of[(fact.wa_cur or -1) + 1]
        return m or nil
    end
    -- yy: the message under the cursor, copied (its words, or a picture's path).
    on("wa_yank", function()
        local m = under_cursor()
        if not m then return end
        local what = (m.text or "") ~= "" and m.text or (m.media or "")
        if what ~= "" then
            pcall(sys.call, "clipboard.set", what)
            text.wa_sub = "Copied"
            fact.wa_has_sub = true
            after(1500, header)
        end
    end)
    -- o: its picture, video, voice note or file; or the first link in what it says.
    on("wa_open", function()
        local m = under_cursor()
        if not m then return end
        if m.kind ~= "text" and m.kind ~= "note" and m.kind ~= "deleted" then
            open_media(m)
            return
        end
        local url = string.match(m.text or "", "https?://[^%s]+")
        if url then
            run("xdg-open", { url }, nil, { output = false })
            fact.expanded = false
        end
    end)
    -- r: answering it. What it answers shows over the field, and goes with the message.
    on("wa_reply", function()
        local m = under_cursor()
        if not m or string.sub(m.id, 1, 4) == "tmp-" then return end
        local who = m.me and "You" or ((m.from or "") ~= "" and m.from or text.wa_name)
        local line = string.match(m.text or "", "^[^\n]*") or ""
        if line == "" then line = ({ image = "📷 Photo", video = "🎥 Video", sticker = "Sticker", audio = "🎤 Voice message", doc = "📄 Document" })[m.kind] or "" end
        quote = { id = m.id, from = who, text = line }
        text.wa_q_from = "Replying to " .. who
        text.wa_q_text = line
        fact.wa_quote = true
        fact.wa_typing = true
    end)
    on("wa_quote_clear", unquote)

    wa_hook.stage = function(path) stage(path) end
    wa_hook.insert = function(words)
        if (words or "") == "" then return end
        text.wa_in = (text.wa_in or "") .. words
        fact.wa_has_in = true
        fact.wa_typing = true
    end
    wa_hook.open = function(jid)
        text.wa_find = ""
        fact.wa_focus = false
        fact.panel = "wa"
        fact.expanded = true
        filter()
        for i, c in ipairs(shown) do if c.jid == jid then choose(i - 1) end end
    end
    wa_hook.act = function(jid, key)
        if key == "reply" then
            wa_hook.open(jid)
            fact.wa_typing = true
        elseif key == "read" then
            send({ op = "read", jid = jid })
        end
    end
    every(60000, function() if looking() then list_show() end end)   -- "Yesterday" comes at midnight
end)()
