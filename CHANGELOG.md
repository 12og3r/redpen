# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.3.2] - 2026-06-11

### Added

- **Anonymous install telemetry.** redpen now counts installs/updates across
  all three channels (Claude Code plugin, Codex CLI plugin, Codex App launcher)
  via a tiny Cloudflare Worker that stores only an integer per channel — no
  prompt text, no IP, no user data. Fires once per machine per version; opt out
  with `REDPEN_NO_TELEMETRY=1`. A live install-count badge is shown in the
  README. See `telemetry/`.

### Fixed

- **Broken `curl | sh` launcher install.** The release now publishes the
  install script, the universal binary, and its `.sha256` (previously only
  `RedPen.dmg` was uploaded, so the curl installer 404'd).

## [0.3.1] - 2026-05-28

### Added

- **Codex Desktop support.** redpen now works with the Codex App (the Electron
  desktop app), not just the Codex CLI. A new launcher app, **Red Pen(Codex)**,
  starts Codex App with redpen grammar/style feedback wired in — without
  modifying `Codex.app` or unpacking its `app.asar`.
- **One-click installer.** Download **RedPen.dmg** from the GitHub release and
  drag **Red Pen(Codex)** to Applications. The launcher bundles a universal
  (`arm64` + `x86_64`) binary. The styled `.dmg` is built in CI with `dmgbuild`,
  so it generates reliably on headless macOS runners.

[0.3.2]: https://github.com/12og3r/redpen/releases/tag/v0.3.2
[0.3.1]: https://github.com/12og3r/redpen/releases/tag/v0.3.1
