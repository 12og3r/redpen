# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.4.4] - 2026-07-28

### Changed

- **Codex coaching now uses a speed-first model fallback chain.** Requests use
  `gpt-5.6-luna` in Fast mode by default, retry with `gpt-5.6-terra` in Fast
  mode on failure, and finally fall back to `gpt-5.4-mini` in Standard mode.

### Fixed

- **Codex feedback no longer starts with blank rows.** The hook now clears
  Codex's `warning:` prefix and writes feedback on that same terminal row
  instead of inserting an additional leading newline. It also avoids adding
  its own left padding on top of Codex's message margin.
- **Desktop checks no longer remain stuck on a half-alive CDP connection.**
  Redpen now verifies the full binding round trip, reconnects an unhealthy
  session, and replays each request with a stable ID without rerunning the
  coach.
- **In-flight feedback survives task switches and renderer replacement.**
  Requests and completed results use a durable outbox/inbox handshake; closing
  the app still converts unfinished checks into an explicit retry state on the
  next launch.
- **Duplicate submit events and nested copies of the same message no longer
  start duplicate checks.**

## [0.4.3] - 2026-07-26

### Fixed

- **Redpen feedback now reloads after editing and resending a prompt in the
  desktop app.** If the app replaces the edited message's DOM branch while a
  check is running, Redpen requeues the submission and attaches the feedback
  to the stable replacement message.

## [0.4.1] - 2026-07-25

### Changed

- **ChatGPT feedback now reads like an inline editorial note.** Translation,
  correction, and unchanged prompts have distinct labels; native phrasing is
  progressively disclosed; and the UI inherits the host theme with responsive,
  keyboard-accessible controls.

### Fixed

- **A broken global Codex CLI no longer blocks setup or silently hides desktop
  coaching.** Both the DMG setup check and ChatGPT launcher prefer the
  app-bundled Codex executable, and the shared runner records subprocess
  failures in the redpen log.

## [0.4.0] - 2026-07-25

### Changed

- **ChatGPT desktop is now the default OpenAI app host.** The redpen launcher
  starts `/Applications/ChatGPT.app`, injects feedback into the unified
  ChatGPT desktop experience, and ships as **Red Pen(ChatGPT)**. The legacy
  Codex app path and `--codex-app` flag remain supported for compatibility.
- **Universal plugin metadata.** The OpenAI plugin now presents as `redpen` in
  the shared ChatGPT and Codex plugin directory while retaining its stable
  `redpen-codex` package ID for existing installations.

## [0.3.2] - 2026-06-11

### Added

- **Anonymous install telemetry.** redpen now counts installs/updates across
  all four channels (Claude Code plugin, Codex CLI plugin, Codex App launcher,
  coco/Trae CLI plugin) via a tiny Cloudflare Worker that stores only an
  integer per channel — no prompt text, no IP, no user data. Fires once per
  machine per version; opt out
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

[0.4.4]: https://github.com/12og3r/redpen/releases/tag/v0.4.4
[0.4.3]: https://github.com/12og3r/redpen/releases/tag/v0.4.3
[0.4.1]: https://github.com/12og3r/redpen/releases/tag/v0.4.1
[0.4.0]: https://github.com/12og3r/redpen/releases/tag/v0.4.0
[0.3.2]: https://github.com/12og3r/redpen/releases/tag/v0.3.2
[0.3.1]: https://github.com/12og3r/redpen/releases/tag/v0.3.1
