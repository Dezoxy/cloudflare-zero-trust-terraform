/**
 * capability-archive -- a private archive with no login form.
 *
 * THE TRUST MODEL
 *
 * Everything lives under an unguessable path, /t/<SITE_TOKEN>/. That token IS
 * the credential. There is no login form, and deliberately no Cloudflare Access
 * in front of this hostname -- which is why the Terraform in this repo carves
 * the hostname out of the wildcard Access app (see public_bypass_subdomains).
 *
 * Putting Access in front would break it: a legitimate link-holder has no
 * Access identity to present. The capability and the identity model are
 * alternatives, not layers.
 *
 * That buys a real property -- a link can be handed to someone with no account,
 * no invite flow, and no user table -- at a real cost: anyone holding the URL
 * is authorised, and the URL cannot be revoked per-recipient. Rotating the
 * token revokes EVERYONE. That trade is only correct for a small, trusted
 * audience, which is exactly what this is for.
 *
 * The token only stays secret if the headers below hold, so they are
 * load-bearing security controls, not hygiene:
 *
 *   Referrer-Policy: no-referrer
 *     Archive content contains outbound links. Without this, clicking one
 *     sends the CURRENT page's URL -- token included -- as the Referer to a
 *     third party. This is the single most likely way such a token leaks.
 *
 *   Cache-Control: private, no-store
 *     The token is in the URL, so any shared cache would key sensitive content
 *     on a secret and hand it to the next requester.
 *
 *   X-Robots-Tag: noindex, nofollow
 *     Belt and braces for a crawler that ignores robots.txt.
 *
 * Two secrets, two audiences, so a leaked reader link never grants write:
 *   SITE_TOKEN  -- reader capability, in the URL path
 *   INGEST_KEY  -- machine credential, sent as a header by the publisher
 */

/** Headers every HTML response carries. See the file header for why. */
const SECURITY_HEADERS = {
  "content-type": "text/html; charset=utf-8",
  "referrer-policy": "no-referrer",
  "cache-control": "private, no-store",
  "x-robots-tag": "noindex, nofollow",
  "x-content-type-options": "nosniff",
};

/**
 * Constant-time secret comparison.
 *
 * A plain `a === b` short-circuits at the first differing byte, so response
 * time leaks a prefix -- enough to recover a token byte by byte over enough
 * requests. Hashing first gives both sides a fixed 32-byte length (
 * timingSafeEqual throws on a length mismatch, which would itself be a signal)
 * and then compares in constant time.
 */
async function secretMatches(provided, expected) {
  if (typeof provided !== "string" || typeof expected !== "string") return false;

  const encoder = new TextEncoder();
  const [a, b] = await Promise.all([
    crypto.subtle.digest("SHA-256", encoder.encode(provided)),
    crypto.subtle.digest("SHA-256", encoder.encode(expected)),
  ]);

  return crypto.subtle.timingSafeEqual(new Uint8Array(a), new Uint8Array(b));
}

/**
 * The only failure response this Worker produces.
 *
 * A wrong token, an unknown path, and a valid token for a missing record all
 * return a byte-identical 404. A 403 on a wrong token would confirm that the
 * path is real and worth attacking; an empty 404 reveals nothing. The site's
 * existence is never acknowledged to someone without the capability.
 */
function notFound() {
  return new Response("Not found", {
    status: 404,
    headers: { "content-type": "text/plain; charset=utf-8", "cache-control": "no-store" },
  });
}

function escapeHtml(value) {
  return String(value).replace(/[&<>"']/g, (c) => (
    { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]
  ));
}

function renderIndex(entries, token) {
  const rows = entries.length
    ? entries.map((e) => `
        <li>
          <a href="/t/${encodeURIComponent(token)}/d/${e.id}">
            <time datetime="${escapeHtml(e.created_at)}">${escapeHtml(e.created_at)}</time>
            <span>${escapeHtml(e.title)}</span>
          </a>
        </li>`).join("")
    : "<li>Nothing published yet.</li>";

  return `<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Archive</title>
<style>
  :root { color-scheme: light dark; }
  body { font: 16px/1.6 system-ui, sans-serif; max-width: 40rem; margin: 3rem auto; padding: 0 1rem; }
  li { margin: .5rem 0; } time { opacity: .6; margin-right: .75rem; font-variant-numeric: tabular-nums; }
</style></head>
<body><h1>Archive</h1><ul>${rows}</ul></body></html>`;
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);

    // Needs no token: it exists precisely so crawlers are told to stay out.
    if (url.pathname === "/robots.txt") {
      return new Response("User-agent: *\nDisallow: /\n", {
        headers: { "content-type": "text/plain; charset=utf-8" },
      });
    }

    // Fail closed. An unset secret must never mean "allow" -- a broken deploy
    // is far better than a silently public archive.
    if (!env.SITE_TOKEN || !env.INGEST_KEY) {
      console.error("SITE_TOKEN or INGEST_KEY unset; refusing all requests");
      return notFound();
    }

    const segments = url.pathname.split("/").filter(Boolean);

    // PUT /ingest/:id -- machine path, guarded by the OTHER secret.
    if (request.method === "PUT" && segments[0] === "ingest" && segments.length === 2) {
      if (!(await secretMatches(request.headers.get("x-ingest-key") ?? "", env.INGEST_KEY))) {
        // 401 here, not 404: this endpoint is for a machine we control, and a
        // clear failure is worth more than concealment. The reader path makes
        // the opposite trade, deliberately.
        return new Response("Unauthorized", { status: 401 });
      }
      return handleIngest(segments[1], request, env);
    }

    // GET /t/:token/... -- reader path.
    if (request.method === "GET" && segments[0] === "t" && segments.length >= 2) {
      if (!(await secretMatches(segments[1], env.SITE_TOKEN))) return notFound();
      return handleRead(segments.slice(2), segments[1], env);
    }

    return notFound();
  },
};

async function handleIngest(rawId, request, env) {
  const id = Number.parseInt(rawId, 10);
  if (!Number.isInteger(id) || id < 1) {
    return new Response("Bad id", { status: 400 });
  }

  let payload;
  try {
    payload = await request.json();
  } catch {
    return new Response("Bad JSON", { status: 400 });
  }

  const title = typeof payload?.title === "string" ? payload.title.trim() : "";
  const body = typeof payload?.body === "string" ? payload.body : "";
  if (!title || !body || title.length > 512 || body.length > 2_000_000) {
    return new Response("Bad payload", { status: 400 });
  }

  // Upsert, so a republished entry updates in place and retries stay idempotent.
  await env.DB.prepare(
    `INSERT INTO entries (id, created_at, title, body)
     VALUES (?1, ?2, ?3, ?4)
     ON CONFLICT(id) DO UPDATE SET
       created_at = excluded.created_at,
       title      = excluded.title,
       body       = excluded.body`
  ).bind(id, payload.created_at ?? new Date().toISOString(), title, body).run();

  return Response.json({ ok: true });
}

async function handleRead(rest, token, env) {
  if (rest.length === 0) {
    const { results } = await env.DB.prepare(
      "SELECT id, created_at, title FROM entries ORDER BY created_at DESC LIMIT 200"
    ).all();
    return new Response(renderIndex(results ?? [], token), { headers: SECURITY_HEADERS });
  }

  if (rest.length === 2 && rest[0] === "d") {
    const id = Number.parseInt(rest[1], 10);
    if (!Number.isInteger(id)) return notFound();

    const row = await env.DB.prepare(
      "SELECT id, created_at, title, body FROM entries WHERE id = ?1"
    ).bind(id).first();
    if (!row) return notFound();

    // `body` is escaped on the way out. If it were ever pre-rendered HTML from
    // upstream, that would be the ONE field inserted raw -- and it would need
    // to be sanitised by the publisher, since this Worker cannot verify it.
    const html = `<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${escapeHtml(row.title)}</title></head>
<body><article><h1>${escapeHtml(row.title)}</h1>
<time datetime="${escapeHtml(row.created_at)}">${escapeHtml(row.created_at)}</time>
<p>${escapeHtml(row.body)}</p></article>
<p><a href="/t/${encodeURIComponent(token)}/">&larr; Back</a></p></body></html>`;

    return new Response(html, { headers: SECURITY_HEADERS });
  }

  return notFound();
}
