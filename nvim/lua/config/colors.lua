-- Personal colorscheme color loader
--
-- active-colorscheme.sh holds the hand-made (eldritch) colours. On top of it,
-- theme/wallpaper-theme.py writes ~/.cache/lumen/term/nvim.sh: the same names,
-- re-hued toward the current wallpaper. Running nvims watch that file and
-- recolour live when the wallpaper changes.

local override_dir = (os.getenv("HOME") or "") .. "/.cache/lumen/term"
local override_file = override_dir .. "/nvim.sh"

-- Read NAME=value lines from a file into `into`; false if it can't be opened
local function read_into(path, into)
  local file = io.open(path, "r")
  if not file then
    return false
  end

  for line in file:lines() do
    if not line:match("^%s*#") and not line:match("^%s*$") and not line:match("^wallpaper=") then
      local name, value = line:match("^(%S+)=%s*(.+)")
      if name and value then
        into[name] = value:gsub('"', "")
      end
    end
  end

  file:close()
  return true
end

-- Function to load colors from the external file(s), into `colors` in place
-- (the colorscheme's on_colors keeps a reference to this very table)
local function load_colors(colors)
  -- Get directory of this file
  local script_dir = debug.getinfo(1, "S").source:sub(2):match("(.*/)")
  local active_file = script_dir .. "active-colorscheme.sh"

  if not read_into(active_file, colors) then
    error("Could not open the active colorscheme file: " .. active_file)
  end
  read_into(override_file, colors)
  return colors
end

-- Load colors when the module is required
local colors = load_colors({})

local function set_groups()
  for name, hex in pairs(colors) do
    vim.api.nvim_set_hl(0, name, { fg = hex })
  end
end

-- Check if the 'vim' global exists (i.e., if running in Neovim)
if _G.vim then
  set_groups()

  -- Recolour when the wallpaper theme rewrites the override file. The file is
  -- replaced by a rename, so watch its directory, not the file.
  local function recolour()
    load_colors(colors)
    if vim.g.colors_name then
      vim.cmd.colorscheme(vim.g.colors_name)
    end
    set_groups()
    package.loaded["config.highlights"] = nil
    pcall(require, "config.highlights")
    local ok, lualine = pcall(require, "lualine")
    if ok then
      lualine.refresh()
    end
  end

  vim.fn.mkdir(override_dir, "p")
  local watcher = vim.uv.new_fs_event()
  if watcher then
    local pending = false
    watcher:start(override_dir, {}, function(err, filename)
      if err or filename ~= "nvim.sh" or pending then
        return
      end
      -- One recolour per burst of events (write + rename)
      pending = true
      vim.defer_fn(function()
        pending = false
        recolour()
      end, 150)
    end)
  end
end

-- Return the colors table for external usage (like wezterm)
return colors
