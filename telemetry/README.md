# redpen telemetry

A tiny Cloudflare Worker that counts **anonymous installs across the four
distribution channels** — Claude Code plugin, Codex CLI plugin, Codex App,
and coco (Trae CLI) plugin — without recording any user data.

## What is and isn't collected

**Collected:** a single integer per channel (`claude`, `codex-cli`,
`codex-app`, `coco`). That's it.

**Never collected:** IP address, User-Agent, prompt text, machine id,
timestamp, location, or any request header. The Worker code never reads them.
See the PRIVACY CONTRACT comment at the top of [`worker.js`](worker.js).

Each client fires **once per installed version** (a local marker file stores
the version). So the channel totals grow with **every install AND every
update** — exactly what you want for an ongoing "installs" number — while a
single user idling on one version is never re-counted. Existing installs are
back-filled once on their first run after this ships. Any user can opt out
entirely by setting `REDPEN_NO_TELEMETRY=1`.

The version is used **only locally** (stored in the marker) to decide when to
re-ping after an update. It is never sent to or stored by the Worker — the only
thing on the wire is the channel label, and each ping is a single KV write.

## How the channels are counted

| Channel | Counted by | When |
|---|---|---|
| `claude` | `plugins/redpen/hooks/grammar_check.sh` (Claude Code hook) | first prompt after each install/update |
| `codex-cli` | `plugins/redpen-codex/shared/coach_codex.sh` (Codex plugin hook, default host) | first prompt after each install/update |
| `codex-app` | the same coach, run by the launcher with `REDPEN_HOST=codex-app` | first prompt after each install/update |
| `coco` | `plugins/redpen-coco/hooks/grammar_check.sh` (coco/Trae CLI hook) | first prompt after each install/update |

All four count **at runtime** (first use per version), so every install method
— marketplace, DMG, curl, local build — is captured uniformly. The Codex App's
DMG/binary downloads are *also* counted natively by GitHub on the Release page
(asset `download_count`), independent of this Worker.

## Deploy (one time)

```sh
cd telemetry

# 1. Log in to Cloudflare
npx wrangler login

# 2. Create the KV namespace, then paste the printed id into wrangler.toml
npx wrangler kv namespace create COUNTS

# 3. Deploy
npx wrangler deploy
```

Wrangler prints your Worker URL, e.g.
`https://redpen-telemetry.<your-subdomain>.workers.dev`.

### Auto-deploy on change (CI)

After the one-time setup above, `.github/workflows/deploy-telemetry.yml`
redeploys the Worker automatically whenever `telemetry/**` changes on `main`
(so editing `worker.js` — e.g. adding a channel — can't silently leave the live
Worker stale). It needs one repository secret, `CLOUDFLARE_API_TOKEN` (a token
with **Workers Scripts: Edit**; add `CLOUDFLARE_ACCOUNT_ID` too if the token
spans multiple accounts). You can still deploy by hand with `wrangler deploy`.

## Wire the clients to your URL

The three ping sites default to this repo's Worker URL; a fork should point
them at its own by editing the `base=` default (or exporting
`REDPEN_TELEMETRY_URL`):

- `plugins/redpen/hooks/grammar_check.sh` — counts `claude`
- `plugins/redpen-codex/shared/coach_codex.sh` — counts `codex-cli` / `codex-app`
- `plugins/redpen-coco/hooks/grammar_check.sh` — counts `coco`

Use the **base** URL (no trailing `/hit`); the clients append `/hit?c=<channel>`.

## Read the numbers

```sh
curl https://redpen-telemetry.<your-subdomain>.workers.dev/stats
# {"claude":12,"codex-cli":4,"codex-app":31,"coco":2,"total":49}
```

### README badge

Shields.io can render a live total from the `/stats` endpoint:

```
![installs](https://img.shields.io/badge/dynamic/json?url=https%3A%2F%2Fredpen-telemetry.redpen.workers.dev%2Fstats&query=%24.total&label=installs&color=brightgreen)
```

`total` = `claude` + `codex-cli` + `codex-app` + `coco` (the Worker sums the
channel counters in `/stats`). Each counter rises by 1 per machine per version
on first use, so `total` is a cumulative count of install/update events across
all channels — not unique humans.

## Who can read / change the numbers

| Action | Who can do it | How |
|---|---|---|
| **Read** counts (`/stats`) | anyone | it's public on purpose (drives the README badge) |
| **Increment** (`/hit`) | anyone with the URL | unauthenticated — can only push numbers *up*, never down or delete |
| **Reset / delete / edit** counts | **only you** | requires your Cloudflare account login (dashboard) or API token (`wrangler`). The Worker exposes **no** delete/decrement route, so there is no public way to clear or lower the data |

So the data **cannot be wiped by anyone else** — clearing it needs access to
your Cloudflare account. The only thing an outsider could do is inflate the
counts by replaying `/hit`. To harden that (optional, not needed for a hobby
project), add one of:

- a Cloudflare **Rate Limiting** rule on the `/hit` path (dashboard, no code), or
- a shared token check in `worker.js` (note: a token shipped inside the public
  install scripts/plugins isn't truly secret, so rate limiting is usually better).

## Notes / limitations

- Counts are best-effort: pings are async and fail silently, so a blocked
  network or offline install simply isn't counted (under-count, never over).
