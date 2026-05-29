# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **Codex Fast Mode for redpen-codex.** The Codex CLI plugin and Codex App
  launcher now request Codex's Fast service tier by default for background
  `codex exec` checks when the configured model supports it, with Standard-mode
  fallback when unsupported. Users can disable it with `FAST_MODE=off` in
  `~/.codex/redpen.config` or through `$redpen-setup`.
- **Advanced Codex model override.** `redpen-codex` still defaults to
  `gpt-5.4-mini`, but `~/.codex/redpen.config` can now set `MODEL=gpt-5.4`
  or another `codex exec --model` value. The setup skill preserves this value.

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

[0.3.1]: https://github.com/12og3r/redpen/releases/tag/v0.3.1
