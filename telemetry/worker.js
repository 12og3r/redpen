// redpen telemetry — privacy-preserving counters (Cloudflare Worker).
//
// PRIVACY CONTRACT: stores only aggregate integers — never the client IP,
// User-Agent, Referer, any header, prompt text, machine id, or geolocation.
// The only thing on the wire is a fixed channel label. Nothing identifies a user.
//
// Two things are tracked:
//   - installs : one integer per channel, in KV          (keys: claude, codex-cli, …)
//   - DAU      : daily-active events written to Analytics Engine; a daily cron
//                rolls each day's per-channel total into KV (keys: dau:<ch>:<date>),
//                so KV takes only ~one write per channel per day (quota-friendly)
//                and the history is kept forever (AE itself only keeps ~90 days).
//
// HTTP routes:
//   GET /hit?c=<channel>     -> +1 install counter for channel; 204 (400 if invalid)
//   GET /active?c=<channel>  -> record a DAU event in AE;        204 (400 if invalid)
//   GET /stats               -> PUBLIC JSON of install counts (drives the badge)
//   GET /dau?token=<secret>  -> PRIVATE JSON of all daily DAU buckets (needs DAU_TOKEN)
//   GET /                    -> liveness
//
// Cron (wrangler.toml triggers): daily at 00:00 UTC -> roll yesterday's AE DAU into KV.
//
// Bindings: COUNTS (KV), AE (Analytics Engine). Vars: CF_ACCOUNT_ID.
// Secrets:  CF_API_TOKEN (Account Analytics: Read, for the cron's AE SQL query),
//           DAU_TOKEN     (gates /dau reads; until set, /dau is 403).

const CHANNELS = ["claude", "codex-cli", "codex-app", "coco"];

// Anti-abuse: a channel must match this shape AND be in the allow-list, else the
// request is rejected (400) and nothing is written. The allow-list alone already
// blocks arbitrary KV keys; the regex is a cheap first gate.
const CHANNEL_RE = /^[a-z][a-z0-9-]{1,31}$/;
const validChannel = (c) => CHANNEL_RE.test(c) && CHANNELS.includes(c);

const utcDay = (d) => d.toISOString().slice(0, 10); // YYYY-MM-DD

export default {
  async fetch(request, env) {
    const url = new URL(request.url);

    if (url.pathname === "/hit") {
      const c = url.searchParams.get("c") || "";
      if (!validChannel(c)) return new Response("bad channel\n", { status: 400 });
      const cur = parseInt((await env.COUNTS.get(c)) || "0", 10);
      await env.COUNTS.put(c, String(cur + 1));
      return new Response(null, { status: 204, headers: { "cache-control": "no-store" } });
    }

    if (url.pathname === "/active") {
      const c = url.searchParams.get("c") || "";
      if (!validChannel(c)) return new Response("bad channel\n", { status: 400 });
      // DAU events go to Analytics Engine only — NOT KV — so daily-active
      // traffic never touches the KV write quota. The cron rolls them up later.
      if (env.AE) {
        try {
          env.AE.writeDataPoint({ indexes: [c], blobs: [c], doubles: [1] });
        } catch (_) { /* never let telemetry break the request */ }
      }
      return new Response(null, { status: 204, headers: { "cache-control": "no-store" } });
    }

    if (url.pathname === "/stats") {
      const out = {};
      let total = 0;
      for (const c of CHANNELS) {
        const n = parseInt((await env.COUNTS.get(c)) || "0", 10);
        out[c] = n;
        total += n;
      }
      out.total = total;
      return Response.json(out, {
        headers: { "access-control-allow-origin": "*", "cache-control": "public, max-age=300" },
      });
    }

    if (url.pathname === "/dau") {
      // PRIVATE: gated by a secret token so DAU is never public (not on a badge).
      const token = url.searchParams.get("token") || "";
      if (!env.DAU_TOKEN || token !== env.DAU_TOKEN) {
        return new Response("forbidden\n", { status: 403 });
      }
      const out = {};
      let cursor;
      do {
        const list = await env.COUNTS.list({ prefix: "dau:", cursor });
        for (const k of list.keys) {
          out[k.name.slice(4)] = parseInt((await env.COUNTS.get(k.name)) || "0", 10);
        }
        cursor = list.list_complete ? undefined : list.cursor;
      } while (cursor);
      return Response.json(out, { headers: { "cache-control": "no-store" } });
    }

    return new Response("redpen telemetry ok\n", { status: 200 });
  },

  // Daily rollup: at 00:00 UTC, query Analytics Engine for *yesterday's* DAU per
  // channel and persist one KV key per channel (permanent history). KV writes
  // here are ~one per active channel per day — well within the free quota.
  async scheduled(event, env, ctx) {
    const yday = utcDay(new Date(Date.now() - 86400000));
    const sql =
      `SELECT blob1 AS channel, SUM(_sample_interval) AS dau ` +
      `FROM redpen_DAU WHERE toDate(timestamp) = '${yday}' GROUP BY channel`;
    const resp = await fetch(
      `https://api.cloudflare.com/client/v4/accounts/${env.CF_ACCOUNT_ID}/analytics_engine/sql`,
      { method: "POST", headers: { Authorization: `Bearer ${env.CF_API_TOKEN}` }, body: sql }
    );
    if (!resp.ok) throw new Error(`AE SQL failed: ${resp.status} ${await resp.text()}`);
    const json = await resp.json();
    for (const row of json.data || []) {
      if (validChannel(row.channel)) {
        await env.COUNTS.put(`dau:${row.channel}:${yday}`, String(Math.round(Number(row.dau) || 0)));
      }
    }
  },
};
