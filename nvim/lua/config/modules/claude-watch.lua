-- claude-watch.lua — watch Claude Code work, in your own nvim.
--
-- `:ClaudeWatch` (or Mod+Shift+D: claude/pane-toggle.sh opens `nvim -c ClaudeWatch`
-- as column 2 of the terminal workspace) turns this nvim into a follower of
-- the Claude you're focused on:
--   - it opens the files Claude reads (a highlight sweeps the lines read),
--   - replays each edit in the buffer: the old text is selected red, lifts
--     into red "removed" rows above (virtual lines, not in the file), the new
--     code types in on green; the latest edit per file stays shown that way,
--   - shows what Claude said it is doing ("why") and the current step in the
--     winbar, and the last command + output in a card at the bottom.
-- It is still your nvim: move, search, jump to definitions, edit. The moment
-- you move, following pauses (winbar says so); <leader>Cf picks it up again.
--
-- Editing alongside Claude:
--   - Claude edits a file you have unsaved changes in: a three-way merge
--     (`git merge-file`: your buffer, what it was last in step with the file,
--     Claude's file). Clean: Claude's change goes in around yours, shown as
--     usual, your changes stay unsaved. A clash: your buffer is left alone,
--     the winbar says so, <leader>Cm opens yours | Claude's side by side
--     (do/dp), and :w asks before writing over Claude's change.
--   - While you type in a file, Claude's edit to it waits for you to leave
--     insert mode.
--   - Each Claude edit is one undo step (u takes it back whole).
--   - A shell command that changes an open file shows like an edit.
--   - No "file changed since reading" prompts for files it keeps in step.
--
-- Fed by claude/hooks/activity.py: one JSON line per tool call in
-- $XDG_RUNTIME_DIR/claude-pane/<session>.jsonl (with the file's original
-- text for edits, Claude's words, the tmux pane). The folder is watched with
-- inotify (vim.uv fs_event): nothing runs while nothing happens. Several
-- Claudes: it follows the one in the tmux pane you focus (tmux hooks write
-- claude-pane/focus), else the one that acted last.
--
-- Keys (this nvim only): <leader>Cf follow again · <leader>Cc every file
-- Claude changed this session (picker, diff preview) · <leader>Cn / Cp next /
-- previous of them · <leader>Cd diffview · <leader>Cw Claude's full words ·
-- <leader>Cm yours vs Claude's (after a clash).

local M = {}
local uv, api = vim.uv, vim.api

local RUN = (vim.env.XDG_RUNTIME_DIR or "/tmp") .. "/claude-pane"
local NS = api.nvim_create_namespace("claude_watch")
local NS_SEL = api.nvim_create_namespace("claude_watch_sel")
local NS_SCAN = api.nvim_create_namespace("claude_watch_scan")
local FRAME_MS = 33
local TYPE_BUDGET = 2.2 -- s: an edit types out in about this long at most
local GHOST_MAX = 6
local G = vim.fn.nr2char -- Nerd Font glyphs by code point (never raw in source)
local CAP_L, CAP_R, ICON = G(0xE0B6), G(0xE0B4), G(0xF069)
local VERB = {
  Read = { 0xF06E, "reading" }, Edit = { 0xF040, "editing" }, MultiEdit = { 0xF040, "editing" },
  Write = { 0xF0F6, "writing" }, Bash = { 0xF120, "running" }, Grep = { 0xF002, "searching" },
  Glob = { 0xF002, "finding" }, WebFetch = { 0xF0AC, "fetching" }, WebSearch = { 0xF0AC, "searching the web" },
  Agent = { 0xF0E7, "delegating" }, Task = { 0xF0E7, "delegating" }, Skill = { 0xF0D0, "using skill" },
}
local BINARY = { png = 1, jpg = 1, jpeg = 1, gif = 1, webp = 1, pdf = 1, zip = 1, gz = 1, mp4 = 1,
  mkv = 1, mp3 = 1, ogg = 1, wav = 1, ttf = 1, otf = 1, woff = 1, woff2 = 1, so = 1, o = 1, pyc = 1 }

local S = {
  on = false, win = nil, follow = true, expect = nil,
  session = nil, offset = 0, partial = "", home = nil,
  queue = {}, anim = nil, timer = nil, fsw = nil, debounce = nil,
  status = nil, why = nil, model = {}, changed = {}, card = nil, cardwin = nil, cardbuf = nil,
  replaying = {}, managed = {},
  base = {},     -- buf -> the file text it was last in step with (merge base)
  conflict = {}, -- buf -> { theirs, path, guard } when Claude's change clashed with yours
  quiet = {},    -- buf -> true while we let nvim re-note the file's time
  waiting_insert = false,
}

local function now() return uv.hrtime() / 1e9 end

local function readf(p)
  local f = io.open(p, "rb")
  if not f then return nil end
  local s = f:read("*a")
  f:close()
  return s
end

local function plain(md)
  md = md:gsub("%*%*(.-)%*%*", "%1"):gsub("__(.-)__", "%1"):gsub("`([^`]*)`", "%1")
  md = md:gsub("%[([^%]]+)%]%([^)]*%)", "%1"):gsub("#", "")
  return vim.trim((md:gsub("%s+", " ")))
end

-- ── colours: from the wallpaper theme, like the terminal and the pane ──────
local function hex(h) return tonumber(h:sub(2, 3), 16), tonumber(h:sub(4, 5), 16), tonumber(h:sub(6, 7), 16) end
local function blend(a, b, t)
  local r1, g1, b1 = hex(a)
  local r2, g2, b2 = hex(b)
  return string.format("#%02x%02x%02x", r1 + (r2 - r1) * t + 0.5, g1 + (g2 - g1) * t + 0.5, b1 + (b2 - b1) * t + 0.5)
end

local function colours()
  local root = vim.fn.resolve(vim.fn.stdpath("config")) .. "/.."
  local c = { bg = "#070a0e", fg = "#ebfafa", accent = "#f94dff", chip = "#3a4357", quiet = "#2a3244",
    [1] = "#f16c75", [2] = "#37f499", [3] = "#f7c67f", [5] = "#fca6ff", [8] = "#646477" }
  for _, p in ipairs({ root .. "/ghostty/ghostty-theme", root .. "/ghostty/wall-colours" }) do
    local t = readf(p) or ""
    for n, h in t:gmatch("palette%s*=%s*(%d+)=(#%x%x%x%x%x%x)") do c[tonumber(n)] = h end
    c.bg = t:match("\nbackground%s*=%s*(#%x+)") or t:match("^background%s*=%s*(#%x+)") or c.bg
    c.fg = t:match("\nforeground%s*=%s*(#%x+)") or c.fg
    c.accent = t:match("\ncursor%-color%s*=%s*(#%x+)") or c.accent
  end
  local tm = readf(vim.fn.expand("~/.cache/lumen/term/tmux.conf")) or ""
  c.accent = tm:match("@t_accent '(#%x+)'") or c.accent
  c.chip = tm:match("@t_chip '(#%x+)'") or c.chip
  c.quiet = tm:match("@t_quiet '(#%x+)'") or c.quiet
  return c
end

local function set_hl()
  local c = colours()
  local muted = blend(c[8], c.fg, 0.45)
  local hl = function(n, v) api.nvim_set_hl(0, n, v) end
  hl("ClaudeWatchAdd", { bg = blend(c.bg, c[2], 0.13) })
  hl("ClaudeWatchAddHi", { bg = blend(c.bg, c[2], 0.32) })
  hl("ClaudeWatchDel", { bg = blend(c.bg, c[1], 0.13), fg = blend(c.bg, c.fg, 0.62) })
  hl("ClaudeWatchDelHi", { bg = blend(c.bg, c[1], 0.36), fg = blend(c.bg, c.fg, 0.8) })
  hl("ClaudeWatchDelSign", { bg = blend(c.bg, c[1], 0.13), fg = c[1], bold = true })
  hl("ClaudeWatchScan", { bg = blend(c.bg, c.accent, 0.14) })
  hl("ClaudeWatchChip", { bg = c.chip, fg = c.accent, bold = true })
  hl("ClaudeWatchCap", { fg = c.chip })
  hl("ClaudeWatchVerb", { fg = c.accent })
  hl("ClaudeWatchStatus", { fg = c.fg })
  hl("ClaudeWatchWhy", { fg = muted })
  hl("ClaudeWatchPaused", { fg = c[3], bold = true })
  hl("ClaudeWatchCard", { bg = c.quiet, fg = muted })
  hl("ClaudeWatchCardHead", { bg = c.quiet, fg = c.fg, bold = true })
  hl("ClaudeWatchCardDim", { bg = c.quiet, fg = c[8] })
  hl("ClaudeWatchCardIcon", { bg = c.quiet, fg = c[5] })
end

-- ── winbar: who, what now, why ─────────────────────────────────────────────
local function esc(s) return (s or ""):gsub("%%", "%%%%") end

local function winbar()
  if not (S.win and api.nvim_win_is_valid(S.win)) then return end
  local parts = { "%#ClaudeWatchCap#", CAP_L, "%#ClaudeWatchChip# ", ICON, " claude ", "%#ClaudeWatchCap#", CAP_R, "%* " }
  if S.status then
    parts[#parts + 1] = "%#ClaudeWatchVerb#" .. G(S.status.icon) .. " %#ClaudeWatchStatus#" .. esc(S.status.text) .. "  "
  elseif not S.session then
    parts[#parts + 1] = "%#ClaudeWatchWhy#waiting for Claude"
  end
  if S.why then -- trimmed to fit, so the chip and the step never scroll off the left
    local used = 22 + (S.status and vim.fn.strdisplaywidth(S.status.text) + 4 or 0)
      + vim.fn.strdisplaywidth(vim.fn.expand("#" .. api.nvim_win_get_buf(S.win) .. ":t")) + 6
      + (S.follow and 0 or 30)
    local room = api.nvim_win_get_width(S.win) - used
    local why = S.why
    if room < 12 then
      why = ""
    elseif vim.fn.strdisplaywidth(why) > room then
      why = vim.fn.strcharpart(why, 0, room - 1):gsub("%s+%S*$", "") .. "…"
    end
    parts[#parts + 1] = "%#ClaudeWatchWhy#" .. esc(why)
  end
  parts[#parts + 1] = "%="
  if S.conflict[api.nvim_win_get_buf(S.win)] then
    parts[#parts + 1] = "%#ClaudeWatchPaused#clashes with Claude · <leader>Cm  "
  end
  if not S.follow then parts[#parts + 1] = "%#ClaudeWatchPaused#paused · <leader>Cf follows  " end
  -- your usual winbar's file part (config/options.lua): modified flag + name
  local n = 0
  for _ in pairs(S.changed) do n = n + 1 end
  if n > 0 then parts[#parts + 1] = "%#ClaudeWatchWhy#" .. n .. " changed · <leader>Cc  " end
  parts[#parts + 1] = "%#WinBar1#%m %#WinBar3#%t "
  vim.wo[S.win].winbar = table.concat(parts)
end

-- ── the command card ───────────────────────────────────────────────────────
local function card_hide()
  if S.cardwin and api.nvim_win_is_valid(S.cardwin) then api.nvim_win_close(S.cardwin, true) end
  S.cardwin = nil
end

local function card_show()
  card_hide()
  local c = S.card
  if not c or not (S.win and api.nvim_win_is_valid(S.win)) then return end
  local lines, hls = {}, {}
  local cmd = vim.trim((c.cmd or ""):gsub("%s+", " "))
  local desc = vim.trim((c.desc or ""):gsub("%s+", " "))
  local icon = " " .. G(0xF120) .. "  "
  if desc ~= "" and desc ~= cmd then
    lines[1] = icon .. desc
    lines[2] = "    $ " .. cmd
    hls = { { 1, "ClaudeWatchCardHead" }, { 2, "ClaudeWatchCardDim" } }
  else
    lines[1] = icon .. "$ " .. cmd
    hls = { { 1, "ClaudeWatchCardHead" } }
  end
  local out = {}
  for l in ((c.out or ""):gsub("\27%[[%d;?]*%a", "")):gmatch("[^\n]+") do
    if l:match("%S") and not l:match("^Shell cwd was reset to ") then out[#out + 1] = "    " .. l:gsub("\t", "    ") end
  end
  for i = math.max(1, #out - 4), #out do lines[#lines + 1] = out[i] end
  if #out == 0 then lines[#lines + 1] = "    no output" end
  S.cardbuf = (S.cardbuf and api.nvim_buf_is_valid(S.cardbuf)) and S.cardbuf or api.nvim_create_buf(false, true)
  api.nvim_buf_set_lines(S.cardbuf, 0, -1, false, lines)
  api.nvim_buf_clear_namespace(S.cardbuf, NS, 0, -1)
  for _, h in ipairs(hls) do
    api.nvim_buf_set_extmark(S.cardbuf, NS, h[1] - 1, 0, { end_row = h[1] - 1, end_col = #lines[h[1]], hl_group = h[2] })
  end
  api.nvim_buf_set_extmark(S.cardbuf, NS, 0, 0, { end_col = #icon, hl_group = "ClaudeWatchCardIcon", priority = 300 })
  local w, h = api.nvim_win_get_width(S.win), api.nvim_win_get_height(S.win)
  S.cardwin = api.nvim_open_win(S.cardbuf, false, {
    relative = "win", win = S.win, row = h - #lines, col = 0, width = w, height = #lines,
    style = "minimal", focusable = false, zindex = 40, noautocmd = true,
  })
  vim.wo[S.cardwin].winhl = "Normal:ClaudeWatchCard"
end

-- ── text helpers (byte offsets, 0-based) ───────────────────────────────────
local function nls(text) -- 0-based offsets of every "\n"
  local t, i = {}, text:find("\n", 1, true)
  while i do
    t[#t + 1] = i - 1
    i = text:find("\n", i + 1, true)
  end
  return t
end

local function before(nl, off) -- how many "\n" sit before offset off
  local lo, hi = 1, #nl
  while lo <= hi do
    local m = math.floor((lo + hi) / 2)
    if nl[m] < off then lo = m + 1 else hi = m - 1 end
  end
  return lo - 1
end

local function rowcol(nl, off)
  local k = before(nl, off)
  return k, off - (k > 0 and nl[k] + 1 or 0)
end

local function cont(b) return b and b >= 0x80 and b < 0xC0 end

local function line_starts(text)
  local t = { 0 }
  for _, p in ipairs(nls(text)) do t[#t + 1] = p + 1 end
  return t
end

-- changed regions top to bottom {ps, pe, qs, qe}, trimmed to the bytes that
-- really change (12 -> 16 is one character)
local function regions(pre, post)
  local ok, hunks = pcall((vim.text and vim.text.diff) or vim.diff, pre, post,
    { result_type = "indices", algorithm = "histogram" })
  if not ok then return {} end
  local pl, ql = line_starts(pre), line_starts(post)
  local function off(ls, i, n) return ls[i] or n end
  local out = {}
  for _, h in ipairs(hunks) do
    local sa, ca, sb, cb = h[1], h[2], h[3], h[4]
    local ps = ca > 0 and off(pl, sa, #pre) or off(pl, sa + 1, #pre)
    local pe = ca > 0 and off(pl, sa + ca, #pre) or ps
    local qs = cb > 0 and off(ql, sb, #post) or off(ql, sb + 1, #post)
    local qe = cb > 0 and off(ql, sb + cb, #post) or qs
    local a, b = pre:sub(ps + 1, pe), post:sub(qs + 1, qe)
    local n, p = math.min(#a, #b), 0
    while p < n and a:byte(p + 1) == b:byte(p + 1) do p = p + 1 end
    while p > 0 and cont(a:byte(p + 1)) do p = p - 1 end
    local s = 0
    while s < n - p and a:byte(#a - s) == b:byte(#b - s) do s = s + 1 end
    while s > 0 and cont(a:byte(#a - s + 1)) do s = s - 1 end
    if pe - s > ps + p or qe - s > qs + p then out[#out + 1] = { ps + p, pe - s, qs + p, qe - s } end
  end
  return out
end

local function apply_edits(text, edits, reverse)
  for i = reverse and #edits or 1, reverse and 1 or #edits, reverse and -1 or 1 do
    local e = edits[i]
    local a, b = e.old, e.new
    if reverse then a, b = b, a end
    local s = text:find(a, 1, true)
    if not s or a == "" then return nil end
    repeat
      text = text:sub(1, s - 1) .. b .. text:sub(s + #a)
      s = e.all and text:find(a, s + #b, true) or nil
    until not s
  end
  return text
end

-- ── buffers ────────────────────────────────────────────────────────────────
local function buf_text(buf) return table.concat(api.nvim_buf_get_lines(buf, 0, -1, false), "\n") end

local function set_text_quiet(buf, text)
  local ul = vim.bo[buf].undolevels
  vim.bo[buf].undolevels = -1
  api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(text, "\n", { plain = true }))
  vim.bo[buf].undolevels = ul
end

local function disk_text(path)
  local d = readf(path)
  return d and (d:gsub("\n$", ""))
end

-- nvim keeps the file's time from when it read it; after we bring the buffer in
-- step with Claude's write, let it note the new time (no "changed since reading")
local function stamp(buf)
  if not api.nvim_buf_is_valid(buf) then return end
  S.quiet[buf] = true
  pcall(vim.cmd, "checktime " .. buf)
  S.quiet[buf] = nil
end

local queue_disk -- below: a file changed on disk outside Claude's edits
local session_files -- below: every file Claude changed this session

local function manage(buf, path)
  if S.managed[buf] then return end
  S.managed[buf] = path
  -- autoread would reload it silently (and as an undo step) before we can
  -- show or merge the change; here every change on disk goes through us
  vim.bo[buf].autoread = false
  if S.base[buf] == nil and not vim.bo[buf].modified and api.nvim_buf_is_loaded(buf) then
    S.base[buf] = buf_text(buf)
  end
  -- The file changes on disk (Claude, a command): we bring the buffer in step
  -- ourselves (replay or merge), so nvim never asks "reload?" or reloads over you.
  api.nvim_create_autocmd("FileChangedShell", {
    buffer = buf,
    callback = function()
      vim.v.fcs_choice = ""
      if S.replaying[buf] or S.quiet[buf] then return end
      vim.schedule(function() queue_disk(buf, path) end)
    end,
  })
  api.nvim_create_autocmd("BufWritePost", {
    buffer = buf,
    callback = function()
      S.base[buf] = buf_text(buf)
      if S.conflict[buf] then
        pcall(api.nvim_del_autocmd, S.conflict[buf].guard)
        S.conflict[buf] = nil
        winbar()
      end
    end,
  })
end

local function open(path) -- -> buf, and whether it was only now read from disk
  local buf = vim.fn.bufadd(path)
  local fresh = not api.nvim_buf_is_loaded(buf)
  vim.fn.bufload(buf)
  vim.bo[buf].buflisted = true
  manage(buf, path)
  return buf, fresh
end

local function main_win() -- an ordinary editor window (the dashboard can sit in a float)
  local cur = api.nvim_get_current_win()
  if api.nvim_win_get_config(cur).relative == "" then return cur end
  for _, w in ipairs(api.nvim_tabpage_list_wins(0)) do
    if api.nvim_win_get_config(w).relative == "" then return w end
  end
  return cur
end

local function show(buf)
  if not S.follow then return false end
  if not (S.win and api.nvim_win_is_valid(S.win)) or api.nvim_win_get_config(S.win).relative ~= "" then
    S.win = main_win()
  end
  if api.nvim_win_get_config(S.win).relative ~= "" then return false end -- never into a float
  if api.nvim_win_get_buf(S.win) ~= buf then api.nvim_win_set_buf(S.win, buf) end
  S.ours = true
  local c = api.nvim_win_get_cursor(S.win) -- our move, not yours
  S.expect = { win = S.win, buf = buf, row = c[1], col = c[2] }
  return true
end

local function goto_pos(buf, row, col) -- 0-based row; keeps the action in the upper third
  if not S.follow or not (S.win and api.nvim_win_is_valid(S.win)) or api.nvim_win_get_buf(S.win) ~= buf then return end
  local n = api.nvim_buf_line_count(buf)
  row = math.max(0, math.min(row, n - 1))
  local line = api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or ""
  -- normal mode keeps the cursor on a character, not past the end: put it
  -- where nvim will leave it, or its own nudge looks like you moving
  col = math.max(0, math.min(col, #line - 1))
  api.nvim_win_set_cursor(S.win, { row + 1, col })
  local h = api.nvim_win_get_height(S.win)
  api.nvim_win_call(S.win, function()
    local top = vim.fn.line("w0")
    if row + 1 < top + math.floor(h * 0.15) or row + 1 > top + math.floor(h * 0.7) then
      vim.fn.winrestview({ topline = math.max(1, row + 1 - math.floor(h * 0.35)) })
    end
  end)
  S.ours = true
  local c = api.nvim_win_get_cursor(S.win) -- where nvim really put it (normal mode clamps the column)
  S.expect = { win = S.win, buf = buf, row = c[1], col = c[2] }
end

-- ── replaying an edit ──────────────────────────────────────────────────────
local function ghost_lines(pre, pnl, ps, pe)
  local l0, l1 = before(pnl, ps), before(pnl, math.max(ps, pe - 1))
  local rows = {}
  for L = l0, l1 do
    local s = L > 0 and pnl[L] + 1 or 0
    local e = pnl[L + 1] or #pre
    local text = pre:sub(s + 1, e)
    local a, b = math.max(ps, s) - s, math.min(pe, e) - s
    rows[#rows + 1] = {
      { "▎ - ", "ClaudeWatchDelSign" },
      { text:sub(1, a), "ClaudeWatchDel" }, { text:sub(a + 1, b), "ClaudeWatchDelHi" },
      { text:sub(b + 1) .. string.rep(" ", 200), "ClaudeWatchDel" },
    }
  end
  if #rows > GHOST_MAX + 1 then
    local more = #rows - GHOST_MAX
    rows = vim.list_slice(rows, 1, GHOST_MAX)
    rows[#rows + 1] = { { "▎   … " .. more .. " more removed" .. string.rep(" ", 200), "ClaudeWatchDelSign" } }
  end
  return rows
end

local function new_anim(buf, pre, post, hurry, instant)
  local A = { buf = buf, pre = pre, post = post, regs = regions(pre, post), ri = 1, phase = "move", t = now(),
    k = 0, pnl = nls(pre), qnl = nls(post), instant = instant }
  local ins, n = 0, #A.regs
  for _, r in ipairs(A.regs) do ins = ins + (r[4] - r[3]) end
  A.t_move = (n < 6 and 0.14 or 0.04) / hurry
  A.t_sel = (n < 6 and 0.28 or 0.08) / hurry
  A.cps = math.max(90 * hurry, ins / math.max(0.25, TYPE_BUDGET / hurry - n * (A.t_move + A.t_sel)))
  S.replaying[buf] = true
  api.nvim_buf_clear_namespace(buf, NS, 0, -1) -- the diff shown is the latest edit's
  if buf_text(buf) ~= pre then set_text_quiet(buf, pre) end
  A.seq0 = vim.fn.undotree(buf).seq_cur -- undo point before this edit (see one_step)
  return A
end

local function anim_step(A)
  local t = now()
  while A.ri <= #A.regs do
    local ps, pe, qs, qe = unpack(A.regs[A.ri])
    local el = t - A.t
    local r0, c0 = rowcol(A.qnl, qs) -- everything above is already "post"
    if A.phase == "move" then
      goto_pos(A.buf, r0, c0)
      if el < A.t_move and not A.instant then return false end
      A.phase = pe > ps and "select" or "lift"
      A.t = t
    elseif A.phase == "select" then
      if not A.selmark then
        local dr = before(A.pnl, pe) - before(A.pnl, ps)
        local er, ec = r0 + dr, dr > 0 and select(2, rowcol(A.pnl, pe)) or c0 + (pe - ps)
        A.del_end = { er, ec }
        A.selmark = api.nvim_buf_set_extmark(A.buf, NS_SEL, r0, c0,
          { end_row = er, end_col = ec, hl_group = "ClaudeWatchDelHi", priority = 300, strict = false })
      end
      if el < A.t_sel and not A.instant then return false end
      A.phase = "lift"
      A.t = t
    elseif A.phase == "lift" then -- the old text leaves the file and shows as removed rows above
      api.nvim_buf_clear_namespace(A.buf, NS_SEL, 0, -1)
      A.selmark = nil
      if pe > ps then
        local er, ec = unpack(A.del_end or { r0, c0 })
        if not A.del_end then
          local dr = before(A.pnl, pe) - before(A.pnl, ps)
          er, ec = r0 + dr, dr > 0 and select(2, rowcol(A.pnl, pe)) or c0 + (pe - ps)
        end
        api.nvim_buf_set_text(A.buf, r0, c0, er, ec, { "" })
        S.ours = true
        api.nvim_buf_set_extmark(A.buf, NS, r0, 0, { virt_lines = ghost_lines(A.pre, A.pnl, ps, pe),
          virt_lines_above = true, right_gravity = false, strict = false })
      end
      A.del_end = nil
      A.cur = { r0, c0 }
      A.ins = A.post:sub(qs + 1, qe)
      A.k = 0
      A.phase = "type"
      A.t = t
    elseif A.phase == "type" then
      local want = A.instant and #A.ins or math.min(#A.ins, math.floor((t - A.t) * A.cps))
      while want < #A.ins and cont(A.ins:byte(want + 1)) do want = want + 1 end
      if want > A.k then
        local chunk = A.ins:sub(A.k + 1, want)
        local parts = vim.split(chunk, "\n", { plain = true })
        local r, c = A.cur[1], A.cur[2]
        api.nvim_buf_set_text(A.buf, r, c, r, c, parts)
        S.ours = true
        if #parts == 1 then c = c + #parts[1] else r, c = r + #parts - 1, #parts[#parts] end
        A.cur = { r, c }
        A.k = want
        -- green: the lines it fills, brighter on what changed
        if A.addmark then pcall(api.nvim_buf_del_extmark, A.buf, NS, A.addmark) end
        if A.himark then pcall(api.nvim_buf_del_extmark, A.buf, NS, A.himark) end
        local endline = api.nvim_buf_get_lines(A.buf, r, r + 1, false)[1] or ""
        A.addmark = api.nvim_buf_set_extmark(A.buf, NS, r0, 0,
          { end_row = r, end_col = #endline, hl_group = "ClaudeWatchAdd", hl_eol = true, priority = 90, strict = false })
        A.himark = api.nvim_buf_set_extmark(A.buf, NS, r0, c0,
          { end_row = r, end_col = c, hl_group = "ClaudeWatchAddHi", priority = 95, strict = false })
        goto_pos(A.buf, r, c)
      end
      if A.k < #A.ins then return false end
      A.addmark, A.himark = nil, nil
      A.ri = A.ri + 1
      A.phase = "move"
      A.t = t
    end
  end
  return true
end

-- The replay typed in many small changes; make the edit one undo step: back to
-- before it, then the whole edit as a single change over the lines it spans.
local function one_step(A)
  if vim.fn.undotree(A.buf).seq_cur == A.seq0 then return end
  api.nvim_buf_call(A.buf, function() pcall(vim.cmd, "silent undo " .. A.seq0) end)
  if buf_text(A.buf) ~= A.pre then return end -- couldn't get back cleanly: keep the steps
  local a = vim.split(A.pre, "\n", { plain = true })
  local b = vim.split(A.post, "\n", { plain = true })
  local p = 0
  while p < #a and p < #b and a[p + 1] == b[p + 1] do p = p + 1 end
  local s = 0
  while s < #a - p and s < #b - p and a[#a - s] == b[#b - s] do s = s + 1 end
  api.nvim_buf_set_lines(A.buf, p, #a - s, false, vim.list_slice(b, p + 1, #b - s))
end

-- the latest edit's diff marks, from its regions (after one_step moved things)
local function remark(A)
  api.nvim_buf_clear_namespace(A.buf, NS, 0, -1)
  for _, r in ipairs(A.regs) do
    local ps, pe, qs, qe = unpack(r)
    local r0, c0 = rowcol(A.qnl, qs)
    if pe > ps then
      api.nvim_buf_set_extmark(A.buf, NS, r0, 0, { virt_lines = ghost_lines(A.pre, A.pnl, ps, pe),
        virt_lines_above = true, right_gravity = false, strict = false })
    end
    if qe > qs then
      local r1, c1 = rowcol(A.qnl, qe)
      local endline = api.nvim_buf_get_lines(A.buf, r1, r1 + 1, false)[1] or ""
      api.nvim_buf_set_extmark(A.buf, NS, r0, 0,
        { end_row = r1, end_col = #endline, hl_group = "ClaudeWatchAdd", hl_eol = true, priority = 90, strict = false })
      api.nvim_buf_set_extmark(A.buf, NS, r0, c0,
        { end_row = r1, end_col = c1, hl_group = "ClaudeWatchAddHi", priority = 95, strict = false })
    end
  end
end

local function anim_finish(A)
  local view = S.win and api.nvim_win_is_valid(S.win) and api.nvim_win_get_buf(S.win) == A.buf
    and api.nvim_win_call(S.win, vim.fn.winsaveview)
  pcall(one_step, A)
  if buf_text(A.buf) ~= A.post then set_text_quiet(A.buf, A.post) end
  pcall(remark, A)
  if view then
    api.nvim_win_call(S.win, function() vim.fn.winrestview(view) end)
    local c = api.nvim_win_get_cursor(S.win)
    S.expect = { win = S.win, buf = A.buf, row = c[1], col = c[2] }
  end
  if A.merge then
    S.base[A.buf] = A.theirs     -- your unsaved changes stay unsaved
  else
    vim.bo[A.buf].modified = false
    S.base[A.buf] = A.post
  end
  S.replaying[A.buf] = nil
  api.nvim_buf_clear_namespace(A.buf, NS_SEL, 0, -1)
  stamp(A.buf)
end

-- ── merging with your unsaved changes ──────────────────────────────────────
local function merge3(ours, base, theirs) -- -> merged text, number of clashes (nil: couldn't)
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p", "0700")
  local function put(name, text)
    local f = io.open(dir .. "/" .. name, "wb")
    f:write(text, "\n")
    f:close()
    return dir .. "/" .. name
  end
  local o, b, t = put("yours", ours), put("before", base), put("claude", theirs)
  local r = vim.system({ "git", "merge-file", "-p", "-L", "yours", "-L", "before", "-L", "claude", o, b, t },
    { text = true }):wait()
  vim.fn.delete(dir, "rf")
  if r.code < 0 or r.code >= 128 or not r.stdout then return nil end
  return (r.stdout:gsub("\n$", "")), r.code
end

local function clash(buf, path, theirs)
  local c = S.conflict[buf] or {}
  S.conflict[buf] = c
  c.theirs, c.path = theirs, path
  if not c.guard then
    -- :w asks first, so your version never silently replaces Claude's
    c.guard = api.nvim_create_autocmd("BufWriteCmd", { buffer = buf, callback = function()
      local name = vim.fn.fnamemodify(path, ":t")
      local ch = vim.fn.confirm("Claude also changed " .. name .. ", and it clashes with your edits.\n"
        .. "Save your version (after merging what you want from Claude's)?", "&Save mine\n&Merge view\n&Cancel", 2)
      if ch == 1 then
        vim.fn.writefile(api.nvim_buf_get_lines(buf, 0, -1, false), path)
        vim.bo[buf].modified = false
        S.base[buf] = buf_text(buf)
        pcall(api.nvim_del_autocmd, c.guard)
        S.conflict[buf] = nil
        stamp(buf)
        winbar()
      elseif ch == 2 then
        M.merge_view(buf)
      end
    end })
  end
  vim.notify("Claude changed " .. vim.fn.fnamemodify(path, ":t")
    .. " where you have unsaved edits, and they clash: <leader>Cm to merge", vim.log.levels.WARN)
  winbar()
end

-- bring a buffer up to Claude's text `theirs`: a replay if it's unmodified, a
-- merge if you have unsaved changes there
local function bring_in(buf, path, theirs, hurry, instant)
  local ours = buf_text(buf)
  if ours == theirs then -- already there: still go and look at it
    S.base[buf] = theirs
    stamp(buf)
    show(buf)
    return { until_t = now() + 0.3 / hurry }
  end
  if not vim.bo[buf].modified then
    return { anim = new_anim(buf, ours, theirs, hurry, instant or not show(buf)) }
  end
  local merged, n = merge3(ours, S.base[buf] or ours, theirs)
  if merged and n == 0 then
    local A = new_anim(buf, ours, merged, hurry, true)
    A.merge, A.theirs = true, theirs
    vim.notify("Merged Claude's edit to " .. vim.fn.fnamemodify(path, ":t") .. " into your unsaved changes")
    return { anim = A }
  end
  clash(buf, path, theirs)
  return nil
end

function M.merge_view(buf)
  buf = buf or api.nvim_get_current_buf()
  local c = S.conflict[buf]
  local path = c and c.path or api.nvim_buf_get_name(buf)
  local theirs = c and c.theirs or disk_text(path)
  if not theirs or theirs == buf_text(buf) then
    vim.notify("Nothing of Claude's to merge here")
    return
  end
  local win = vim.fn.bufwinid(buf)
  if win == -1 then
    vim.cmd("buffer " .. buf)
  else
    api.nvim_set_current_win(win)
  end
  S.follow = false
  vim.cmd("diffthis")
  vim.cmd("vertical rightbelow new")
  local sb = api.nvim_get_current_buf()
  api.nvim_buf_set_lines(sb, 0, -1, false, vim.split(theirs, "\n", { plain = true }))
  vim.bo[sb].buftype, vim.bo[sb].bufhidden, vim.bo[sb].swapfile = "nofile", "wipe", false
  vim.bo[sb].filetype = vim.bo[buf].filetype
  vim.bo[sb].modifiable = false
  pcall(api.nvim_buf_set_name, sb, "claude://" .. vim.fn.fnamemodify(path, ":t"))
  vim.cmd("diffthis")
  vim.wo.winbar = "%#ClaudeWatchChip# " .. ICON .. " Claude's version %* %#ClaudeWatchWhy#"
    .. "do / dp take a change across · q closes · then :w yours"
  vim.keymap.set("n", "q", function()
    vim.cmd("diffoff!")
    pcall(api.nvim_win_close, 0, true)
  end, { buffer = sb })
  winbar()
end

-- ── actions ────────────────────────────────────────────────────────────────
local function action_of(e)
  local tool, p = e.tool, e.path
  if (tool == "Edit" or tool == "MultiEdit") and p then
    local pre = e.orig or S.model[p]
    if not pre then
      local disk = readf(p)
      pre = disk and apply_edits(disk, e.edits or {}, true)
    end
    local post = pre and apply_edits(pre, e.edits or {})
    if not post then post = readf(p) or ""; pre = pre or post end
    S.model[p] = post
    return { kind = "edit", e = e, path = p, pre = pre:gsub("\n$", ""), post = post:gsub("\n$", "") }
  elseif tool == "Write" and p then
    local pre = e.orig or S.model[p] or ""
    local post = e.content or readf(p) or ""
    S.model[p] = post
    return { kind = "edit", e = e, path = p, pre = pre:gsub("\n$", ""), post = post:gsub("\n$", "") }
  elseif tool == "Read" and p and not BINARY[(p:match("%.([%w]+)$") or ""):lower()] then
    return { kind = "read", e = e, path = p }
  elseif tool == "Bash" then
    return { kind = "bash", e = e }
  end
  return { kind = "note", e = e }
end

local function describe(e)
  local v = VERB[e.tool] or { 0xF111, e.tool:lower() }
  local what = e.path and vim.fn.fnamemodify(e.path, ":t") or vim.trim(((e.what or ""):gsub("%s+", " ")))
  return { icon = v[1], text = v[2] .. (what ~= "" and (" " .. what) or "") }
end

local function start_action(a, hurry, instant)
  local e = a.e
  S.status = describe(e)
  if e.why then S.why = plain(e.why) end
  if a.kind ~= "bash" then card_hide() end
  if a.kind == "edit" then
    S.changed[a.path] = { t = e.t, path = a.path }
    local buf, fresh = open(a.path)
    if fresh then -- just read from disk (already Claude's): start from before its edit
      set_text_quiet(buf, a.pre)
      vim.bo[buf].modified = false
      S.base[buf] = a.pre
    end
    return bring_in(buf, a.path, a.post, hurry, instant)
  elseif a.kind == "disk" then -- a command (or anything) changed an open file
    local theirs = disk_text(a.path)
    if not theirs or not api.nvim_buf_is_valid(a.buf) then return nil end
    S.status = { icon = 0xF120, text = "a command changed " .. vim.fn.fnamemodify(a.path, ":t") }
    S.changed[a.path] = { t = os.time(), path = a.path }
    return bring_in(a.buf, a.path, theirs, hurry, instant)
  elseif a.kind == "read" then
    local buf = open(a.path)
    if not vim.bo[buf].modified and not S.replaying[buf] then
      -- the file as it was when Claude read it: if one of its edits is still
      -- queued, the disk is already ahead; that edit's "before" is the truth
      local disk = readf(a.path)
      for _, q in ipairs(S.queue) do
        if q.kind == "edit" and q.path == a.path then disk = q.pre; break end
      end
      if disk and disk:gsub("\n$", "") ~= buf_text(buf) then
        set_text_quiet(buf, disk:gsub("\n$", ""))
        vim.bo[buf].modified = false
        stamp(buf)
      end
      S.base[buf] = buf_text(buf)
    end
    if show(buf) and not instant then
      local first = math.max(0, (e.offset or 1) - 1)
      local n = api.nvim_buf_line_count(buf)
      local last = math.min(n - 1, first + (e.limit or n) - 1)
      goto_pos(buf, first, 0)
      return { scan = { buf = buf, first = first, last = last, t0 = now() }, until_t = now() + 0.75 / hurry }
    end
    return nil
  elseif a.kind == "bash" then
    for _, p in ipairs(e.changed or {}) do S.changed[p] = { t = e.t, path = p } end
    S.card = { cmd = e.cmd or e.what or "", desc = e.what or "", out = e.out or "" }
    card_show()
    for buf, path in pairs(S.managed) do
      if api.nvim_buf_is_valid(buf) and api.nvim_buf_is_loaded(buf) then queue_disk(buf, path) end
    end
    return { until_t = now() + 0.4 / hurry }
  end
  return { until_t = now() + 0.2 / hurry }
end

local function step_scan(sc)
  local t = now() - sc.t0
  api.nvim_buf_clear_namespace(sc.buf, NS_SCAN, 0, -1)
  if t > 0.75 then return end
  local head = sc.first + math.floor((sc.last - sc.first + 6) * math.min(1, t / 0.6))
  local a, b = math.max(sc.first, head - 8), math.min(sc.last, head)
  if b >= a then
    api.nvim_buf_set_extmark(sc.buf, NS_SCAN, a, 0, { end_row = b, end_col = 0, hl_group = "ClaudeWatchScan",
      hl_eol = true, line_hl_group = "ClaudeWatchScan", strict = false })
  end
end

local tick

local function run()
  if S.timer and S.timer:is_active() then return end
  S.timer = S.timer or uv.new_timer()
  S.timer:start(0, FRAME_MS, vim.schedule_wrap(tick))
end

tick = function()
  for _ = 1, 50 do
    if not S.cur and #S.queue > 0 then
      local nx = S.queue[1]
      if nx.kind == "edit" or nx.kind == "disk" then
        local b = nx.buf or vim.fn.bufnr(nx.path)
        if b == api.nvim_get_current_buf() and api.nvim_get_mode().mode:match("^[iR]") then
          S.waiting_insert = true -- after you leave insert mode (InsertLeave)
          S.timer:stop()
          return
        end
      end
      local a = table.remove(S.queue, 1)
      local hurry = 1 + 0.8 * math.min(#S.queue, 6)
      local ok, cur = pcall(start_action, a, hurry, #S.queue > 8)
      S.cur = ok and cur or nil
      if not ok then vim.notify("claude-watch: " .. tostring(cur), vim.log.levels.DEBUG) end
      winbar()
    end
    if not S.cur then break end
    local c = S.cur
    if c.scan then step_scan(c.scan) end
    local done
    if c.anim then
      local ok, d = pcall(anim_step, c.anim)
      done = not ok or d
      if done then pcall(anim_finish, c.anim) end
    else
      done = now() >= (c.until_t or 0)
    end
    if not done then return end
    if c.scan then api.nvim_buf_clear_namespace(c.scan.buf, NS_SCAN, 0, -1) end
    S.cur = nil
  end
  if not S.cur and #S.queue == 0 and S.timer then S.timer:stop() end
end

queue_disk = function(buf, path)
  if not S.on then return end
  for _, a in ipairs(S.queue) do -- Claude's own edit to it is coming: that shows it
    if a.path == path then return end
  end
  if S.cur and S.cur.anim and S.cur.anim.buf == buf then return end
  local d = disk_text(path)
  if not d or d == buf_text(buf) or d == S.base[buf] then return end
  S.queue[#S.queue + 1] = { kind = "disk", e = { tool = "Bash" }, buf = buf, path = path }
  run()
end

-- ── the log ────────────────────────────────────────────────────────────────
local function logs()
  local out = {}
  local h = uv.fs_scandir(RUN)
  if not h then return out end
  while true do
    local name = uv.fs_scandir_next(h)
    if not name then break end
    if name:match("%.jsonl$") then
      local st = uv.fs_stat(RUN .. "/" .. name)
      if st and os.time() - st.mtime.sec < 86400 then out[name:sub(1, -7)] = { path = RUN .. "/" .. name, mtime = st.mtime.sec + st.mtime.nsec / 1e9, size = st.size } end
    end
  end
  return out
end

local function tail_events(path, bytes)
  local f = io.open(path, "rb")
  if not f then return {} end
  local size = f:seek("end")
  f:seek("set", math.max(0, size - bytes))
  local data = f:read("*a")
  f:close()
  local evs = {}
  for line in data:gmatch("[^\n]+") do
    local ok, d = pcall(vim.json.decode, line)
    if ok and type(d) == "table" then evs[#evs + 1] = d end
  end
  return evs
end

local function pick()
  local L = logs()
  if next(L) == nil then return nil end
  local focus = vim.trim(readf(RUN .. "/focus") or "")
  if focus ~= "" then
    for sid, l in pairs(L) do
      local ev = tail_events(l.path, 65536)
      if ev[#ev] and ev[#ev].tmux == focus then return sid, L end
    end
    if S.session and L[S.session] then return S.session, L end
  end
  local best, bt = nil, -1
  for sid, l in pairs(L) do
    if l.mtime > bt then best, bt = sid, l.mtime end
  end
  return best, L
end

local function switch(sid, L)
  S.session, S.queue, S.cur, S.model, S.changed = sid, {}, nil, {}, {}
  for b in pairs(S.replaying) do S.replaying[b] = nil end
  local l = L[sid]
  S.offset, S.partial = l.size, ""
  local f = io.open(l.path, "rb")
  local first = f and f:read("*l")
  if f then f:close() end
  local ok, d = pcall(vim.json.decode, first or "")
  S.home = ok and type(d) == "table" and d.cwd or nil
  if S.home and S.win and api.nvim_win_is_valid(S.win) then
    api.nvim_win_call(S.win, function() pcall(vim.cmd.tcd, vim.fn.fnameescape(S.home)) end)
  end
  -- where it is now: its last file and words, no replay
  local evs = tail_events(l.path, 262144)
  S.status, S.why = nil, nil
  for i = #evs, 1, -1 do
    local e = evs[i]
    if not S.why and e.why then S.why = plain(e.why) end
    if not S.status then S.status = describe(e) end
    if e.path and not BINARY[(e.path:match("%.([%w]+)$") or ""):lower()] and S.follow then
      local buf = open(e.path)
      show(buf)
      -- land on its last change, not the top of the file
      local ed = e.edits and e.edits[#e.edits]
      local needle = ed and (ed.new:match("[^\n]*%S[^\n]*") or "")
      if needle and needle ~= "" then
        local lines = api.nvim_buf_get_lines(buf, 0, -1, false)
        for i, l in ipairs(lines) do
          if l:find(needle, 1, true) then goto_pos(buf, i - 1, 0); break end
        end
      elseif e.offset then
        goto_pos(buf, e.offset - 1, 0)
      end
      break
    end
  end
  winbar()
  vim.schedule(function() -- the whole session's changed files (log read once, cached)
    for _, it in ipairs(session_files()) do S.changed[it.path] = { t = it.t, path = it.path } end
    winbar()
  end)
end

local function read_new()
  local L = logs()
  local l = S.session and L[S.session]
  if not l then return end
  if l.size < S.offset then S.offset = l.size end -- rotated: start from here
  if l.size == S.offset then return end
  local f = io.open(l.path, "rb")
  if not f then return end
  f:seek("set", S.offset)
  local data = S.partial .. (f:read("*a") or "")
  f:close()
  S.offset = l.size
  local last_nl = data:match(".*()\n")
  if not last_nl then S.partial = data; return end
  S.partial = data:sub(last_nl + 1)
  for line in data:sub(1, last_nl):gmatch("[^\n]+") do
    local ok, e = pcall(vim.json.decode, line)
    if ok and type(e) == "table" and e.tool then S.queue[#S.queue + 1] = action_of(e) end
  end
  run()
end

local function changed()
  if not S.on then return end
  local sid, L = pick()
  if not sid then return end
  if sid ~= S.session then switch(sid, L) else read_new() end
end

-- ── follow / pause ─────────────────────────────────────────────────────────
local function pause()
  if S.follow then
    S.follow = false
    winbar()
  end
end

function M.follow()
  S.follow, S.expect = true, nil
  if not (S.win and api.nvim_win_is_valid(S.win)) then S.win = main_win() end
  local last
  for _, c in pairs(S.changed) do if not last or c.t > last.t then last = c end end
  if last then show(open(last.path)) end
  winbar()
end

-- ── every file Claude changed this session ─────────────────────────────────
-- From the whole session log (cached by its size): each file's text before
-- Claude first touched it (the hook's "orig"; a Write with none = a new file),
-- how many edits, when last. The diff shown is that first text vs the file now.
local files_cache = { log = nil, size = -1, list = {} }

session_files = function()
  if not S.session then
    local sid = pick()
    if not sid then return {} end
    S.session = S.session or sid
  end
  local log = RUN .. "/" .. S.session .. ".jsonl"
  local st = uv.fs_stat(log)
  if not st then return {} end
  if files_cache.log == log and files_cache.size == st.size then return files_cache.list end
  local by = {}
  local f = io.open(log, "rb")
  if f then
    for line in f:lines() do
      local tool = line:match('"tool":%s*"(%w+)"')
      if tool == "Bash" and line:find('"changed"', 1, true) then -- files a command changed
        local ok, e = pcall(vim.json.decode, line)
        if ok and type(e) == "table" and type(e.changed) == "table" then
          for _, p in ipairs(e.changed) do
            local it = by[p]
            if not it then
              it = { path = p, edits = 0, t = 0, by_command = true }
              by[p] = it
            end
            it.edits = it.edits + 1
            it.t = math.max(it.t, e.t or 0)
          end
        end
      elseif tool == "Edit" or tool == "Write" or tool == "MultiEdit" or tool == "NotebookEdit" then
        local ok, e = pcall(vim.json.decode, line)
        if ok and type(e) == "table" and e.path then
          local it = by[e.path]
          if not it then
            local before = e.orig
            if before == nil and e.tool == "Write" then before = "" end
            it = { path = e.path, before = before, edits = 0, t = 0 }
            by[e.path] = it
          end
          it.edits = it.edits + 1
          it.t = math.max(it.t, e.t or 0)
          if e.orig then it.last_before = e.orig end -- before its latest edit
        end
      end
    end
    f:close()
  end
  local list = {}
  for _, it in pairs(by) do list[#list + 1] = it end
  table.sort(list, function(a, b) return a.t > b.t end)
  files_cache = { log = log, size = st.size, list = list }
  return list
end

local function before_of(it) -- the file before Claude touched it this session
  local before = it.before
  if before == nil then -- changed by a command (or before the hook kept originals): vs the last commit
    local dir = vim.fn.fnamemodify(it.path, ":h")
    local r = vim.system({ "git", "-C", dir, "show", "HEAD:./" .. vim.fn.fnamemodify(it.path, ":t") },
      { text = true }):wait()
    before = r.code == 0 and r.stdout or "" -- not in git: all of it is new
  end
  return (before:gsub("\n$", ""))
end

-- mark in the buffer everything Claude changed in it this session (green
-- lines, brighter changed text, red removed rows), like a live edit's marks
local function mark_session(buf, it)
  if not (it and api.nvim_buf_is_loaded(buf)) then return end
  local before, now_text = before_of(it), buf_text(buf)
  -- a file Claude created this session would be all green: show its latest edit
  if before == "" and it.last_before and it.edits > 1 then before = (it.last_before:gsub("\n$", "")) end
  if before == now_text then
    api.nvim_buf_clear_namespace(buf, NS, 0, -1)
    return
  end
  pcall(remark, { buf = buf, pre = before, post = now_text, regs = regions(before, now_text),
    pnl = nls(before), qnl = nls(now_text) })
end

local function session_item(path)
  for _, it in ipairs(session_files()) do
    if it.path == path then return it end
  end
end

local function file_diff(it) -- -> unified diff text, adds, dels, first changed line
  local buf = vim.fn.bufnr(it.path)
  local now_text = (buf ~= -1 and api.nvim_buf_is_loaded(buf)) and buf_text(buf) or disk_text(it.path)
  if now_text == nil then return "(the file is gone)", 0, 0, 1 end
  local before = before_of(it)
  local d = ((vim.text and vim.text.diff) or vim.diff)(before .. "\n", now_text .. "\n", { ctxlen = 3 }) or ""
  local adds, dels, first = 0, 0, nil
  for l in d:gmatch("[^\n]+") do
    if l:sub(1, 1) == "+" then adds = adds + 1 elseif l:sub(1, 1) == "-" then dels = dels + 1 end
    if not first then first = tonumber(l:match("^@@ %-%d+,?%d* %+(%d+)")) end
  end
  if d == "" then d = "(no difference from before Claude's edits)" end
  return d, adds, dels, first or 1
end

local function open_changed(path, line, it) -- your pick: show it, stop following
  if not (S.win and api.nvim_win_is_valid(S.win)) then S.win = main_win() end
  api.nvim_set_current_win(S.win)
  local buf = open(path)
  api.nvim_win_set_buf(S.win, buf)
  mark_session(buf, it or session_item(path))
  pcall(api.nvim_win_set_cursor, S.win, { math.max(1, line or 1), 0 })
  vim.cmd("normal! zz")
  if S.on then S.follow = false end
  winbar()
end

function M.changes()
  local list = session_files()
  if #list == 0 then
    vim.notify("Claude hasn't changed any files in this session yet")
    return
  end
  local ok, Snacks = pcall(require, "snacks")
  if not ok or not Snacks.picker then -- no picker: the quickfix list
    local qf = {}
    for _, it in ipairs(list) do
      local _, a, d, first = file_diff(it)
      qf[#qf + 1] = { filename = it.path, lnum = first, text = string.format("+%d -%d · %d edits", a, d, it.edits) }
    end
    vim.fn.setqflist({}, " ", { title = "Changed by Claude", items = qf })
    vim.cmd("copen")
    return
  end
  local items = {}
  for i, it in ipairs(list) do
    local diff, a, d, first = file_diff(it)
    local name = vim.fn.fnamemodify(it.path, ":t")
    local dir = vim.fn.fnamemodify(it.path, ":~:.:h")
    local b = vim.fn.bufnr(it.path)
    items[#items + 1] = {
      idx = i, score = 0, text = name .. " " .. dir, file = it.path, pos = { first, 0 },
      name = name, dir = dir, adds = a, dels = d, edits = it.edits, t = it.t,
      mine = b ~= -1 and vim.bo[b].modified, by_command = it.by_command, it = it,
      preview = { text = diff, ft = "diff" },
    }
  end
  Snacks.picker({
    title = "Changed by Claude (" .. #items .. ")",
    items = items,
    preview = "preview",
    format = function(item)
      return {
        { item.mine and "● " or "  ", "DiagnosticWarn" },
        { item.name, "SnacksPickerFile" },
        { "  " .. item.dir .. "  ", "Comment" },
        { "+" .. item.adds, "Added" }, { " " },
        { "-" .. item.dels, "Removed" },
        { string.format("  %d %s%s · %s", item.edits, item.by_command and "command" or "edit",
          item.edits == 1 and "" or "s", os.date("%H:%M", math.floor(item.t))), "Comment" },
      }
    end,
    confirm = function(picker, item)
      picker:close()
      if item then open_changed(item.file, item.pos[1], item.it) end
    end,
  })
end

M._session_files = function() return session_files() end -- (for checks)

-- step through the changed files, newest first (<leader>Cn / <leader>Cp)
function M.cycle(dir)
  local list = session_files()
  if #list == 0 then return end
  local cur = api.nvim_buf_get_name(api.nvim_get_current_buf())
  local k = 0
  for i, it in ipairs(list) do if it.path == cur then k = i end end
  k = ((k - 1 + dir) % #list) + 1
  local _, _, _, first = file_diff(list[k])
  open_changed(list[k].path, first, list[k])
  vim.notify(string.format("%d/%d  %s", k, #list, vim.fn.fnamemodify(list[k].path, ":~:.")))
end

function M.why()
  local text = S.why or "Nothing yet."
  local lines = {}
  for _, para in ipairs(vim.split(text, "\n")) do
    for _, l in ipairs(vim.split(vim.fn.trim(vim.fn.substitute(para, [[\(.\{1,72\}\)\(\s\|$\)]], "\\1\n", "g")), "\n")) do
      lines[#lines + 1] = " " .. l .. " "
    end
  end
  local buf = api.nvim_create_buf(false, true)
  api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  local w = 0
  for _, l in ipairs(lines) do w = math.max(w, vim.fn.strdisplaywidth(l)) end
  local win = api.nvim_open_win(buf, true, { relative = "cursor", row = 1, col = 0, width = math.max(20, w),
    height = #lines, style = "minimal", border = "rounded", title = " what Claude is doing ", title_pos = "center" })
  vim.keymap.set("n", "q", "<cmd>close<cr>", { buffer = buf })
  vim.keymap.set("n", "<esc>", "<cmd>close<cr>", { buffer = buf })
  api.nvim_create_autocmd("WinLeave", { buffer = buf, once = true, callback = function() pcall(api.nvim_win_close, win, true) end })
end

function M.start()
  if S.on then M.follow(); return end
  if vim.v.vim_did_enter ~= 1 then -- `nvim +ClaudeWatch`: after startup (and the dashboard), not under it
    api.nvim_create_autocmd("VimEnter", { once = true, callback = function() vim.defer_fn(M.start, 80) end })
    return
  end
  S.on, S.win = true, main_win()
  -- the startup dashboard (and its floats) make way
  for _, w in ipairs(api.nvim_tabpage_list_wins(0)) do
    if w ~= S.win and api.nvim_win_get_config(w).relative ~= "" then pcall(api.nvim_win_close, w, true) end
  end
  set_hl()
  local grp = api.nvim_create_augroup("ClaudeWatch", { clear = true })
  api.nvim_create_autocmd("ColorScheme", { group = grp, callback = function() set_hl(); winbar() end })
  api.nvim_create_autocmd({ "CursorMoved", "InsertEnter" }, { group = grp, callback = function(ev)
    if not S.follow or api.nvim_get_current_win() ~= S.win then return end
    if ev.event == "InsertEnter" then return pause() end
    local c = api.nvim_win_get_cursor(S.win)
    if S.ours then -- the move our own change caused (text shifting under the cursor)
      S.ours = false
      S.expect = { win = S.win, buf = api.nvim_get_current_buf(), row = c[1], col = c[2] }
      return
    end
    local x = S.expect
    if not x then return end
    -- yours if it left the line (or the file) or went more than a column off
    if x.buf ~= api.nvim_get_current_buf() or x.row ~= c[1] or math.abs(x.col - c[2]) > 1 then pause() end
  end })
  -- options.lua sets the global winbar on BufEnter/ModeChanged; the watch window keeps its own
  api.nvim_create_autocmd({ "BufEnter", "ModeChanged" }, { group = grp, callback = function()
    vim.schedule(winbar)
  end })
  -- every file you open is kept in step (and merged with) too, not only Claude's
  api.nvim_create_autocmd("BufReadPost", { group = grp, callback = function(ev)
    if vim.bo[ev.buf].buftype == "" and ev.file ~= "" then
      S.base[ev.buf] = buf_text(ev.buf)
      manage(ev.buf, api.nvim_buf_get_name(ev.buf))
    end
  end })
  api.nvim_create_autocmd("BufEnter", { group = grp, callback = function(ev)
    if S.replaying[ev.buf] or vim.bo[ev.buf].buftype ~= "" then return end
    if #api.nvim_buf_get_extmarks(ev.buf, NS, 0, -1, { limit = 1 }) > 0 then return end
    local it = session_item(api.nvim_buf_get_name(ev.buf))
    if it then mark_session(ev.buf, it) end
  end })
  api.nvim_create_autocmd("InsertLeave", { group = grp, callback = function()
    if S.waiting_insert then S.waiting_insert = false; run() end
  end })
  api.nvim_create_autocmd({ "WinResized", "VimResized" }, { group = grp, callback = function()
    if S.cardwin then card_show() end
  end })
  local map = function(l, f, d) vim.keymap.set("n", l, f, { desc = d }) end
  map("<leader>Cf", M.follow, "Claude: follow again")
  map("<leader>Cc", M.changes, "Claude: every file it changed this session")
  map("<leader>Cn", function() M.cycle(1) end, "Claude: next changed file")
  map("<leader>Cp", function() M.cycle(-1) end, "Claude: previous changed file")
  map("<leader>Cd", function() pcall(vim.cmd, "DiffviewOpen") end, "Claude: diff of the repo")
  map("<leader>Cw", M.why, "Claude: what it says it's doing")
  map("<leader>Cm", function() M.merge_view() end, "Claude: yours vs Claude's (merge)")
  for _, b in ipairs(api.nvim_list_bufs()) do -- files already open
    if api.nvim_buf_is_loaded(b) and vim.bo[b].buftype == "" and api.nvim_buf_get_name(b) ~= "" then
      manage(b, api.nvim_buf_get_name(b))
    end
  end

  vim.fn.mkdir(RUN, "p", "0700")
  S.fsw = uv.new_fs_event()
  S.debounce = uv.new_timer()
  S.fsw:start(RUN, {}, function()
    S.debounce:stop()
    S.debounce:start(25, 0, vim.schedule_wrap(changed))
  end)
  changed()
  winbar()
end

return M
