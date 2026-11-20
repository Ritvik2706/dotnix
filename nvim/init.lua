-- Debloated Neovim Configuration
-- Keeps: aesthetic, file management, search/replace, navigation, tmux, copy/paste

-- Enable Lua bytecode cache (Neovim 0.9+) — speeds up all require() calls significantly
vim.loader.enable()

-- Markdown heading background style (solid or transparent)
vim.g.md_heading_bg = vim.env.MD_HEADING_BG or "transparent"

-- Disable snacks animations for performance
vim.g.snacks_animate = false

-- Suppress startup warnings we can't fix (LazyVim mason rename, treesitter CLI)
local _orig_notify = vim.notify
vim.notify = function(msg, level, opts)
  if type(msg) == "string" then
    if msg:find("mason%-lspconfig") or msg:find("mason%.nvim") or msg:find("tree%-sitter") or msg:find("nvim%-treesitter.*main")
      or msg:find("Publish Diagnostics") or msg:find("Validate documents") or msg:find("jdtls") then
      return
    end
  end
  _orig_notify(msg, level, opts)
end

-- Bootstrap lazy.nvim
require("config.lazy")

-- Restore vim.notify after plugins load (noice will replace it anyway)
vim.defer_fn(function()
  if vim.notify == _orig_notify then
    vim.notify = _orig_notify
  end
end, 1000)

-- Load custom highlights (must be loaded after colorscheme to avoid being overridden)
require("config.highlights")

-- :ClaudeWatch — follow Claude Code in this nvim (config/modules/claude-watch.lua;
-- Mod+Shift+D opens one beside the terminal)
vim.api.nvim_create_user_command("ClaudeWatch", function()
  require("config.modules.claude-watch").start()
end, { desc = "Follow Claude Code: replay its reads and edits here" })
