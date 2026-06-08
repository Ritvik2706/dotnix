local M = {}

-- Persists across mini.files buffer creates (navigation re-creates buffers)
local yanked_fs_entry = nil

-- Platform flags — resolved once at module load. has() is a static feature
-- check, but caching it keeps the per-action paths free of any OS probing.
local is_wsl = vim.fn.has("wsl") == 1
local is_mac = vim.fn.has("mac") == 1

-- The system clipboard "copy" command, resolved lazily on first use and then
-- cached for the session — the chosen tool can't change mid-session, so there's
-- no point re-probing executable() on every yank. `false` = resolved, none found.
local clipboard_copy_cmd = nil
local function resolve_clipboard_copy_cmd()
  if is_wsl and vim.fn.executable("clip.exe") == 1 then
    return { "clip.exe" }
  elseif os.getenv("WAYLAND_DISPLAY") and vim.fn.executable("wl-copy") == 1 then
    return { "wl-copy" }
  elseif vim.fn.executable("xclip") == 1 then
    return { "xclip", "-selection", "clipboard" }
  end
  return false
end

-- Copy a string to the system clipboard. Text is passed on stdin (no shell
-- escaping / spurious trailing newline). Returns ok, err.
local function copy_to_system_clipboard(text)
  if clipboard_copy_cmd == nil then
    clipboard_copy_cmd = resolve_clipboard_copy_cmd()
  end
  if not clipboard_copy_cmd then
    return false, "No clipboard tool found (need clip.exe, wl-clipboard, or xclip)"
  end
  vim.fn.system(clipboard_copy_cmd, text)
  if vim.v.shell_error ~= 0 then
    return false, "Clipboard copy failed"
  end
  return true
end

M.setup = function(opts)
  -- Create an autocmd to set buffer-local mappings when a `mini.files` buffer is opened
  -- I use this to open the highlighted directory in a tmux pane on the right
  -- I call the `tmux_pane_functiontmux_pane_function` I defined in my
  -- keympaps.lua file
  vim.api.nvim_create_autocmd("User", {
    -- Updated pattern to match what Echasnovski has in the documentation
    -- https://github.com/nvim-mini/mini.nvim/blob/c6eede272cfdb9b804e40dc43bb9bff53f38ed8a/doc/mini-files.txt#L508-L529
    pattern = "MiniFilesBufferCreate",
    callback = function(args)
      local buf_id = args.data.buf_id
      -- Import 'mini.files' module
      local mini_files = require("mini.files")
      -- Ensure opts.custom_keymaps exists
      local keymaps = opts.custom_keymaps or {}

      -- Open the highlighted directory in a tmux pane on the right
      vim.keymap.set("n", keymaps.open_tmux_pane, function()
        -- vim.keymap.set("n", ",", function()
        -- Get the current entry using 'get_fs_entry()'
        local curr_entry = mini_files.get_fs_entry()
        if curr_entry and curr_entry.fs_type == "directory" then
          -- Call tmux pane function with the directory path
          require("config.keymaps").tmux_pane_function(curr_entry.path)
        else
          -- Notify if not a directory or no entry is selected
          vim.notify("Not a directory or no entry selected", vim.log.levels.WARN)
        end
      end, { buffer = buf_id, noremap = true, silent = true })

      -- Copy the current file or directory path to the system clipboard
      -- (WSL / Wayland / X11 — see copy_to_system_clipboard)
      vim.keymap.set("n", keymaps.copy_to_clipboard, function()
        -- Get the current entry (file or directory)
        local curr_entry = mini_files.get_fs_entry()
        if curr_entry then
          local path = curr_entry.path
          local ok, err = copy_to_system_clipboard(path)
          if not ok then
            vim.notify(err, vim.log.levels.ERROR)
          else
            vim.notify(vim.fn.fnamemodify(path, ":t"), vim.log.levels.INFO)
            vim.notify("File path copied to clipboard", vim.log.levels.INFO)
          end
        else
          vim.notify("No file or directory selected", vim.log.levels.WARN)
        end
      end, { buffer = buf_id, noremap = true, silent = true, desc = "[P]Copy file/directory to clipboard" })

      -- ZIP current file or directory and copy to the system clipboard
      vim.keymap.set("n", keymaps.zip_and_copy, function()
        local curr_entry = require("mini.files").get_fs_entry()
        if curr_entry then
          local path = curr_entry.path
          local name = vim.fn.fnamemodify(path, ":t") -- Extract the file or directory name
          local parent_dir = vim.fn.fnamemodify(path, ":h") -- Get the parent directory
          local timestamp = os.date("%y%m%d%H%M%S") -- Append timestamp to avoid duplicates
          local zip_path = string.format("/tmp/%s_%s.zip", name, timestamp) -- Path in macOS's tmp directory
          -- Create the zip file
          local zip_cmd = string.format(
            "cd %s && zip -r %s %s",
            vim.fn.shellescape(parent_dir),
            vim.fn.shellescape(zip_path),
            vim.fn.shellescape(name)
          )
          local result = vim.fn.system(zip_cmd)
          if vim.v.shell_error ~= 0 then
            vim.notify("Failed to create zip file: " .. result, vim.log.levels.ERROR)
            return
          end
          -- Copy the zip path to the clipboard (WSL / Wayland / X11)
          local ok, err = copy_to_system_clipboard(zip_path)
          if not ok then
            vim.notify("Failed to copy zip path to clipboard: " .. err, vim.log.levels.ERROR)
            return
          end
          vim.notify(zip_path, vim.log.levels.INFO)
          vim.notify("Zipped and path copied to clipboard: ", vim.log.levels.INFO)
        else
          vim.notify("No file or directory selected", vim.log.levels.WARN)
        end
      end, { buffer = buf_id, noremap = true, silent = true, desc = "[P]Zip and copy to clipboard" })

      -- Paste the file/directory currently on the system clipboard into the
      -- current mini.files directory. Supported on WSL (Windows clipboard) and
      -- macOS; native Linux clipboards don't carry file references uniformly.
      vim.keymap.set("n", keymaps.paste_from_clipboard, function()
        -- vim.notify("Starting the paste operation...", vim.log.levels.INFO)
        if not mini_files then
          vim.notify("mini.files module not loaded.", vim.log.levels.ERROR)
          return
        end
        local curr_entry = mini_files.get_fs_entry() -- Get the current file system entry
        if not curr_entry then
          vim.notify("Failed to retrieve current entry in mini.files.", vim.log.levels.ERROR)
          return
        end
        local curr_dir = curr_entry.fs_type == "directory" and curr_entry.path
          or vim.fn.fnamemodify(curr_entry.path, ":h") -- Use parent directory if entry is a file
        -- vim.notify("Current directory: " .. curr_dir, vim.log.levels.INFO)

        -- Resolve the source path from the clipboard, per platform.
        local source_path
        if is_wsl then
          -- Windows clipboard: take the first entry of the FileDropList and map
          -- the resulting Windows path back to a WSL path.
          local ps = "$f=(Get-Clipboard -Format FileDropList); if ($f) { $f[0].FullName }"
          local win = vim.fn.system({ "powershell.exe", "-NoProfile", "-NonInteractive", "-Command", ps })
          win = win:gsub("%s+$", "")
          if win == "" then
            vim.notify("Clipboard does not contain a file.", vim.log.levels.WARN)
            return
          end
          source_path = vim.fn.system({ "wslpath", "-u", win }):gsub("%s+$", "")
        elseif is_mac then
          local script = [[
              tell application "System Events"
                try
                  set theFile to the clipboard as alias
                  set posixPath to POSIX path of theFile
                  return posixPath
                on error
                  return "error"
                end try
              end tell
            ]]
          local output = vim.fn.system("osascript -e " .. vim.fn.shellescape(script))
          if vim.v.shell_error ~= 0 or output:find("error") then
            vim.notify("Clipboard does not contain a valid file or directory.", vim.log.levels.WARN)
            return
          end
          source_path = output:gsub("%s+$", "")
        else
          vim.notify("Paste-from-clipboard isn't supported on this platform.", vim.log.levels.WARN)
          return
        end

        if source_path == "" then
          vim.notify("Clipboard is empty or invalid.", vim.log.levels.WARN)
          return
        end
        local dest_path = curr_dir .. "/" .. vim.fn.fnamemodify(source_path, ":t") -- Destination path in current directory
        local copy_cmd = vim.fn.isdirectory(source_path) == 1 and { "cp", "-R", source_path, dest_path }
          or { "cp", source_path, dest_path } -- Construct copy command
        local result = vim.fn.system(copy_cmd) -- Execute the copy command
        if vim.v.shell_error ~= 0 then
          vim.notify("Paste operation failed: " .. result, vim.log.levels.ERROR)
          return
        end
        -- vim.notify("Pasted " .. source_path .. " to " .. dest_path, vim.log.levels.INFO)
        mini_files.synchronize() -- Refresh mini.files to show updated directory content
        vim.notify("Pasted successfully.", vim.log.levels.INFO)
      end, { buffer = buf_id, noremap = true, silent = true, desc = "[P]Paste from clipboard" })

      -- Copy the current file or directory path (relative to home) to clipboard
      vim.keymap.set("n", keymaps.copy_path, function()
        -- Get the current entry (file or directory)
        local curr_entry = mini_files.get_fs_entry()
        if curr_entry then
          -- Convert path to be relative to home directory
          local home_dir = vim.fn.expand("~")
          local relative_path = curr_entry.path:gsub("^" .. home_dir, "~")
          vim.fn.setreg("+", relative_path) -- Copy the relative path to the clipboard register
          vim.notify(vim.fn.fnamemodify(relative_path, ":t"), vim.log.levels.INFO)
          vim.notify("Path copied to clipboard: ", vim.log.levels.INFO)
        else
          vim.notify("No file or directory selected", vim.log.levels.WARN)
        end
      end, { buffer = buf_id, noremap = true, silent = true, desc = "[P]Copy relative path to clipboard" })

      -- Preview with image viewer instead of QuickLook
      vim.keymap.set("n", keymaps.preview_image, function()
        local curr_entry = mini_files.get_fs_entry()
        if curr_entry then
          -- Use Linux image viewer
          local command
          if vim.fn.executable("feh") == 1 then
            command = "feh " .. vim.fn.shellescape(curr_entry.path) .. " &"
          elseif vim.fn.executable("eog") == 1 then
            command = "eog " .. vim.fn.shellescape(curr_entry.path) .. " &"
          else
            command = "xdg-open " .. vim.fn.shellescape(curr_entry.path) .. " &"
          end
          vim.fn.system(command)
        else
          vim.notify("No file selected", vim.log.levels.WARN)
        end
      end, { buffer = buf_id, noremap = true, silent = true, desc = "[P]Preview with image viewer" })

      -- Duplicate file: yy to yank current entry, p to paste copy into current dir.
      -- yyp in plain vim just yanks/pastes the filename text, which is wrong here.
      vim.keymap.set("n", "yy", function()
        local curr_entry = mini_files.get_fs_entry()
        if not curr_entry then
          vim.notify("No entry selected", vim.log.levels.WARN)
          return
        end
        yanked_fs_entry = curr_entry
        vim.notify("Yanked: " .. vim.fn.fnamemodify(curr_entry.path, ":t"), vim.log.levels.INFO)
      end, { buffer = buf_id, noremap = true, silent = true, desc = "[P]Yank file/dir entry" })

      vim.keymap.set("n", "p", function()
        if not yanked_fs_entry then
          vim.notify("Nothing yanked — use yy first", vim.log.levels.WARN)
          return
        end
        local curr_entry = mini_files.get_fs_entry()
        local dest_dir
        if curr_entry then
          dest_dir = curr_entry.fs_type == "directory"
            and curr_entry.path
            or vim.fn.fnamemodify(curr_entry.path, ":h")
        else
          dest_dir = vim.fn.fnamemodify(yanked_fs_entry.path, ":h")
        end

        local src_path = yanked_fs_entry.path
        local src_name = vim.fn.fnamemodify(src_path, ":t")
        local ext      = vim.fn.fnamemodify(src_name, ":e")
        local base     = vim.fn.fnamemodify(src_name, ":r")

        local function make_dest(suffix)
          if ext ~= "" then
            return dest_dir .. "/" .. base .. suffix .. "." .. ext
          else
            return dest_dir .. "/" .. src_name .. suffix
          end
        end

        local dest_path = dest_dir .. "/" .. src_name
        if vim.fn.filereadable(dest_path) == 1 or vim.fn.isdirectory(dest_path) == 1 then
          dest_path = make_dest("_copy")
          local i = 2
          while vim.fn.filereadable(dest_path) == 1 or vim.fn.isdirectory(dest_path) == 1 do
            dest_path = make_dest("_copy" .. i)
            i = i + 1
          end
        end

        local copy_cmd = yanked_fs_entry.fs_type == "directory"
          and { "cp", "-r", src_path, dest_path }
          or  { "cp", src_path, dest_path }

        local result = vim.fn.system(copy_cmd)
        if vim.v.shell_error ~= 0 then
          vim.notify("Duplicate failed: " .. result, vim.log.levels.ERROR)
        else
          mini_files.synchronize()
          vim.notify("Duplicated as: " .. vim.fn.fnamemodify(dest_path, ":t"), vim.log.levels.INFO)
        end
      end, { buffer = buf_id, noremap = true, silent = true, desc = "[P]Paste/duplicate yanked entry" })

      -- End of keymaps
    end,
  })
end

return M
