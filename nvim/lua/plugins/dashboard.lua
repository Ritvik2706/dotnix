-- Start screen: animated octopus, centered, until a file is opened.
--
-- All tunables (which gif, speed, loop, position, size, colors) live in
-- lua/config/splash-settings.lua — start there to tweak the look.
--
-- The art is brrtfetch's brrt.gif (https://github.com/ferrebarrat/brrtfetch)
-- pre-rendered to half-block frames in lua/config/splashes/octopus.lua by
-- scripts/gif-to-splash.py. Playback is handled by
-- config/modules/splash-player.lua, which holds the animation whenever the
-- dashboard is not on screen.

return {
  {
    "folke/snacks.nvim",
    opts = function(_, opts)
      local settings = require("config.splash-settings")
      local splash = require(settings.module)

      -- Register the animation autocmds now, before the dashboard first opens
      if settings.animate then
        require("config.modules.splash-player").setup(splash, settings)
      end

      -- Hide the cursor while the dashboard is the active buffer: a fully
      -- transparent cursor highlight (blend = 100) applied for normal/visual
      -- mode only, so the cursor still shows in the cmdline, mini.files, etc.
      local group = vim.api.nvim_create_augroup("dashboard_hide_cursor", { clear = true })
      local saved -- guicursor to restore; non-nil means we're hiding
      local function hide()
        if saved then return end
        vim.api.nvim_set_hl(0, "DashboardHiddenCursor", { blend = 100, nocombine = true })
        saved = vim.go.guicursor
        vim.go.guicursor = saved .. ",n-v:block-DashboardHiddenCursor"
      end
      local function restore()
        if not saved then return end
        vim.go.guicursor = saved
        saved = nil
      end
      vim.api.nvim_create_autocmd("User", {
        group = group,
        pattern = "SnacksDashboardOpened",
        callback = hide,
      })
      vim.api.nvim_create_autocmd("BufEnter", {
        group = group,
        callback = function()
          if vim.bo.filetype == "snacks_dashboard" then hide() else restore() end
        end,
      })
      -- colorschemes wipe custom highlights; re-blend if we're mid-hide
      vim.api.nvim_create_autocmd("ColorScheme", {
        group = group,
        callback = function()
          if saved then
            vim.api.nvim_set_hl(0, "DashboardHiddenCursor", { blend = 100, nocombine = true })
          end
        end,
      })

      -- Seed the header with frame 1 — the player anchors the animation to it
      opts.dashboard = {
        enabled = true,
        -- Keep the dashboard pane at least as wide as the art so it centers
        width = math.max(56, splash.cols or 0),
        preset = {
          header = table.concat(splash.frames[1], "\n"),
        },
        -- Header only: no keys, no recent files, no startup time
        sections = {
          { section = "header", padding = settings.padding },
        },
      }
    end,
  },
}
