# redpen telemetry

A tiny Cloudflare Worker that counts **anonymous installs across the three
distribution channels** — Claude Code plugin, Codex CLI plugin, and Codex App
— without recording any user data.

## What is and isn't collected

**Collected:** a single integer per channel (`claude`, `codex-cli`,
`codex-app`). That's it.

**Never collected:** IP address, User-Agent, prompt text, machine id,
timestamp, location, or any request header. The Worker code never reads them.
See the PRIVACY CONTRACT comment at the top of [`worker.js`](worker.js).

Each client fires **once per installed version** (a local marker file stores
the version). So the channel totals grow with **every install AND every
update** — exactly what you want for an ongoing "installs" number — while a
single user idling on one version is never re-counted. Existing installs are
back-filled once on their first run after this ships. Any user can opt out
entirely by setting `REDPEN_NO_TELEMETRY=1`.

The plugin version is sent as `&v=<version>` (software metadata, not user
data); the Worker keeps an optional per-version breakdown under `byVersion` in
`/stats`.

## How the channels are counted

| Channel | Counted by | When |
|---|---|---|
| `codex-app` | `scripts/install-codex-app.sh` ping **and** GitHub Release asset download stats | every install/update (the install script re-runs) |
| `claude` | `plugins/redpen/hooks/grammar_check.sh` ping | first prompt after each install/update |
| `codex-cli` | `plugins/redpen-codex/shared/coach_codex.sh` ping | first prompt after each install/update |

> The Codex App is also counted natively by GitHub on the Release page
> (asset download_count). The ping just unifies all three into one dashboard.

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

## Wire the clients to your URL

After deploying, set that URL as `REDPEN_TELEMETRY_URL` in three places (each
currently holds a `REPLACE_WITH_...` placeholder and is a **no-op until you do
this**):

- `plugins/redpen/hooks/grammar_check.sh`
- `plugins/redpen-codex/shared/coach_codex.sh`
- `scripts/install-codex-app.sh`

Use the **base** URL (no trailing `/hit`); the clients append `/hit?c=<channel>`.

## Read the numbers

```sh
curl https://redpen-telemetry.<your-subdomain>.workers.dev/stats
# {"claude":12,"codex-cli":4,"codex-app":31,"total":47,
#  "byVersion":{"claude:0.3.2":12,"codex-cli:0.3.2":4,"codex-app:0.3.2":31}}
```

### README badge

Shields.io can render a live total from the `/stats` endpoint:

```
![installs](https://img.shields.io/badge/dynamic/json?url=https%3A%2F%2Fredpen-telemetry.redpen.workers.dev%2Fstats&query=%24.total&label=installs&color=brightgreen)
```

`total` = `claude` + `codex-cli` + `codex-app` (the Worker sums the three
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
