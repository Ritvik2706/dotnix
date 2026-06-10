-- Core Neovim options — debloated

-- Disable ALL remote providers upfront — we have no LSP so none are needed.
-- This eliminates the provider startup probes which each cost a process fork.
vim.g.loaded_python3_provider = 0
vim.g.loaded_node_provider    = 0
vim.g.loaded_perl_provider    = 0
vim.g.loaded_ruby_provider    = 0

-- Encoding
vim.opt.fileencoding  = "utf-8"
vim.opt.fileencodings = "utf-8,ucs-bom,latin1"

-- Leader key
vim.g.mapleader = " "

-- Clipboard via clip.exe / powershell.exe — WSL-native, no probe delay.
-- Neovim's default clipboard probing times out on each missing tool (wl-paste,
-- xclip, etc.) causing a multi-second startup freeze. Explicitly setting
-- vim.g.clipboard skips all probing entirely.
local is_wsl = vim.fn.has("wsl") == 1
if is_wsl then
  if vim.fn.executable("win32yank.exe") == 1 then
    -- win32yank is a native binary — much faster than powershell.
    vim.g.clipboard = {
      name  = "win32yank",
      copy  = {
        ["+"] = { "win32yank.exe", "-i", "--crlf" },
        ["*"] = { "win32yank.exe", "-i", "--crlf" },
      },
      paste = {
        ["+"] = { "win32yank.exe", "-o", "--lf" },
        ["*"] = { "win32yank.exe", "-o", "--lf" },
      },
      cache_enabled = 1,
    }
  else
    -- Fallback: powershell. Avoid spawning bash+tr+sed; do CRLF→LF inside
    -- powershell with -join and cache the result so repeated pastes don't
    -- re-invoke powershell.
    vim.g.clipboard = {
      name  = "WSL",
      copy  = {
        ["+"] = { "clip.exe" },
        ["*"] = { "clip.exe" },
      },
      paste = {
        ["+"] = { "powershell.exe", "-NoProfile", "-NonInteractive", "-Command",
                  "[Console]::OutputEncoding=[System.Text.Encoding]::UTF8;(Get-Clipboard) -join \"`n\"" },
        ["*"] = { "powershell.exe", "-NoProfile", "-NonInteractive", "-Command",
                  "[Console]::OutputEncoding=[System.Text.Encoding]::UTF8;(Get-Clipboard) -join \"`n\"" },
      },
      cache_enabled = 1,
    }
  end
end
vim.opt.clipboard = "unnamedplus"

-- Line numbers
vim.opt.number = true
vim.opt.relativenumber = true

-- Timeout for key mappings
vim.opt.timeout = true
vim.opt.timeoutlen = 300
vim.opt.ttimeout = true
vim.opt.ttimeoutlen = 0
vim.opt.ttyfast = true

-- updatetime: used by gitsigns to update the sign column
vim.o.updatetime = 200

-- Conceallevel (0 = show all symbols)
vim.opt.conceallevel = 0

-- Spell checking
vim.opt.spelllang = { "en" }

-- Text wrapping at 80 characters
vim.opt.textwidth = 80
vim.opt.wrap = true

-- Show colorcolumn at 80 for markdown guidelines
vim.opt.colorcolumn = "80"

-- Sign column always visible (for gitsigns)
vim.opt.signcolumn = "yes"

-- Persist undo history across sessions (stored in stdpath("state")/undo/)
vim.opt.undofile = true

-- Use ripgrep for :grep / :cgrep — results go to the quickfix list.
-- (Snacks.picker.grep is separate and unaffected by this.)
vim.opt.grepprg    = "rg --vimgrep --smart-case"
vim.opt.grepformat = "%f:%l:%c:%m"

-- Keep some lines above/below the cursor when scrolling
vim.opt.scrolloff = 10
-- smoothscroll + scrolloff=999 causes a jarring full-file animation on gg/G
vim.opt.smoothscroll = false

-- Session options
vim.opt.sessionoptions = {
  "buffers", "curdir", "tabpages", "winsize",
  "help", "globals", "skiprtp", "folds", "localoptions",
}

-- Cursor appearance
vim.opt.guicursor = {
  "n-v-c-sm:block-Cursor",
  "i-ci-ve:ver25-lCursor",
  "r-cr:hor20-CursorIM",
}

-- ─── Winbar ────────────────────────────────────────────────────────────────────

local function shorten_path(path)
  local shorten_if_more_than = 6
  local prefix = ""
  if path:sub(1, 2) == "~/" then
    prefix = "~/"
    path = path:sub(3)
  elseif path:sub(1, 1) == "/" then
    prefix = "/"
    path = path:sub(2)
  end
  local parts = {}
  for part in string.gmatch(path, "[^/]+") do
    table.insert(parts, part)
  end
  if #parts > shorten_if_more_than then
    return prefix .. parts[1] .. "/../" .. table.concat({
      parts[#parts - 3], parts[#parts - 2], parts[#parts - 1], parts[#parts],
    }, "/")
  end
  return prefix .. table.concat(parts, "/")
end

local function get_winbar_path()
  local ft = vim.bo.filetype
  local name = vim.api.nvim_buf_get_name(0)
  local full_path
  if ft == "minifiles" then
    -- mini.files buffers are named minifiles://<id>/<abs path of the
    -- directory being browsed> — show that directory
    full_path = name:match("^minifiles://%d+/(.*)$") or vim.uv.cwd()
  elseif ft == "snacks_dashboard" or name == "" then
    full_path = vim.uv.cwd()
  else
    full_path = vim.fn.expand("%:p:h")
  end
  return (full_path:gsub(vim.fn.expand("$HOME"), "~"))
end

local function get_buffer_count()
  return vim.fn.len(vim.fn.getbufinfo({ buflisted = 1 }))
end

local function update_winbar()
  local display_path = shorten_path(get_winbar_path())
  local buffer_count = get_buffer_count()
  vim.opt.winbar = "%#WinBar1#%m "
    .. "%#WinBar2#(" .. buffer_count .. ") "
    .. "%#WinBar3#" .. vim.fn.expand("%:t")
    .. "%*%=%#WinBar1#" .. display_path
end

vim.api.nvim_create_autocmd({ "BufEnter", "ModeChanged" }, {
  callback = function(args)
    local old_mode = args.event == "ModeChanged" and vim.v.event.old_mode or ""
    local new_mode = args.event == "ModeChanged" and vim.v.event.new_mode or ""
    if args.event == "ModeChanged" then
      local buf_ft = vim.bo.filetype
      if buf_ft == "snacks_terminal" or old_mode:match("^t") or new_mode:match("^n") then
        update_winbar()
      end
    else
      update_winbar()
    end
  end,
})
