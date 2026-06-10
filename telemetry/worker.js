// redpen telemetry — privacy-preserving install counter (Cloudflare Worker).
//
// PRIVACY CONTRACT: this Worker stores ONLY an integer count per channel in
// KV. It NEVER reads, stores, or logs the client IP, User-Agent, Referer, any
// other request header, prompt text, machine id, timestamp, or geolocation.
// The only data that crosses the wire is a fixed channel label from a short
// allow-list. There is nothing here that can identify a user.
//
// Routes:
//   GET /hit?c=<channel>  -> increment that channel's counter; return 204
//   GET /stats            -> public JSON of all counts (read-only)
//   GET /                 -> liveness string
//
// KV binding (see wrangler.toml): COUNTS

const CHANNELS = ["claude", "codex-cli", "codex-app"];

export default {
  async fetch(request, env) {
    const url = new URL(request.url);

    if (url.pathname === "/hit") {
      const c = url.searchParams.get("c") || "";
      // Only known channels are counted; anything else is silently ignored so
      // a malformed/abusive label can't create arbitrary KV keys.
      if (CHANNELS.includes(c)) {
        // One write per ping. The counter grows with every install AND every
        // update — the client decides when to ping (version-aware marker); the
        // version itself is never sent or stored here, only the channel label.
        const cur = parseInt((await env.COUNTS.get(c)) || "0", 10);
        await env.COUNTS.put(c, String(cur + 1));
      }
      // No body, not cacheable. We deliberately read nothing else off the
      // request — the IP the edge sees is never touched by this code.
      return new Response(null, {
        status: 204,
        headers: { "cache-control": "no-store" },
      });
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
        headers: {
          "access-control-allow-origin": "*",
          "cache-control": "public, max-age=300",
        },
      });
    }

    return new Response("redpen telemetry ok\n", { status: 200 });
  },
};
