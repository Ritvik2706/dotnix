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

local function show(path)
    version += 1
    -- A versioned name reloads into the same atlas slot instead of taking new room.
    text.cover_path = path .. "?" .. version
    fact.has_art = true
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
    end
end

sys.watch("media", cover)


on("toggle", function() sys.call("media.toggle") end)
on("next", function() sys.call("media.next") end)
on("previous", function() sys.call("media.previous") end)

-- ── workspaces ──────────────────────────────────────────────────────
-- A workspace shows when it has windows or is the active one (empty ones take
-- no room, as in waybar).
local active_ws = 1
sys.watch("workspaces", function(w)
    local busy = {}
    for _, d in ipairs(w.list) do
        if d.windows > 0 then busy[d.id] = true end
    end
    active_ws = w.active
    fact.ws_active = w.active
    for i = 1, 10 do
        fact["ws." .. i .. ".there"] = busy[i] or i == w.active
    end
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

-- ── cpu and memory: no service for these, so /proc, every 5 s (waybar's pace)
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
every(5000, sample)
