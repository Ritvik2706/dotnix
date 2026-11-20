-- rustaceanvim (LazyVim's lang.rust extra): no rust-analyzer "health status"
-- popups. They are long (a loose .rs with no Cargo.toml, a stable toolchain
-- asked for nightly flags) and noice drew them over the code. Real problems
-- still show as diagnostics; details: :RustLsp logFile.
return {
  {
    "mrcjkb/rustaceanvim",
    opts = {
      server = { status_notify_level = false },
    },
  },
}
