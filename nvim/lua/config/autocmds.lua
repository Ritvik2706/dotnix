-- Essential autocmds — debloated

local function augroup(name)
  return vim.api.nvim_create_augroup("lazyvim_" .. name, { clear = true })
end

-- Close certain file types with <esc> or q
vim.api.nvim_create_autocmd("FileType", {
  group = augroup("close_with_q"),
  pattern = {
    "PlenaryTestPopup",
    "grug-far",
    "help",
    "lspinfo",
    "notify",
    "qf",
    "startuptime",
    "checkhealth",
    "gitsigns-blame",
    "Lazy",
  },
  callback = function(event)
    vim.bo[event.buf].buflisted = false
    vim.schedule(function()
      vim.keymap.set("n", "<esc>", function()
        vim.cmd("close")
        pcall(vim.api.nvim_buf_delete, event.buf, { force = true })
      end, {
        buffer = event.buf,
        silent = true,
        desc = "Quit buffer",
      })
    end)
  end,
})

-- Highlight on yank
vim.api.nvim_create_autocmd("TextYankPost", {
  group = augroup("highlight_yank"),
  callback = function()
    vim.highlight.on_yank({ higroup = "IncSearch", timeout = 150 })
  end,
})

-- Open mini.files when nvim is launched with a directory (e.g. nvim .)
vim.api.nvim_create_autocmd("VimEnter", {
  group = augroup("open_dir_with_mini_files"),
  callback = function()
    local arg = vim.fn.argv(0)
    if arg and vim.fn.isdirectory(arg) == 1 then
      vim.schedule(function() require("mini.files").open(arg, true) end)
    end
  end,
})

-- Disable spell in markdown (LazyVim enables it; this runs after and overrides it)
vim.api.nvim_create_autocmd("FileType", {
  group = augroup("markdown_nospell"),
  pattern = "markdown",
  callback = function()
    vim.opt_local.spell = false
  end,
})

-- Restore cursor position when opening a file
vim.api.nvim_create_autocmd("BufReadPost", {
  group = augroup("restore_cursor"),
  callback = function()
    local mark = vim.api.nvim_buf_get_mark(0, '"')
    local lcount = vim.api.nvim_buf_line_count(0)
    if mark[1] > 0 and mark[1] <= lcount then
      pcall(vim.api.nvim_win_set_cursor, 0, mark)
    end
  end,
})
