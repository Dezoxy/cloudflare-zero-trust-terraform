# capability-archive

A private archive with **no login form**, demonstrating capability-link
authentication and the Cloudflare Access carve-out it requires.

## The idea

The whole site lives under an unguessable path, `/t/<SITE_TOKEN>/`. Holding the
URL *is* being authorised. There is no user table, no invite flow, and no
session.

This is why the Terraform in this repo lists the hostname in
`public_bypass_subdomains`: it must be carved out of the wildcard Access
application. Putting Access in front would break it outright, because a
legitimate link-holder has no Access identity to present. **The capability model
and the identity model are alternatives, not layers.**

## The trade-off

Worth stating plainly, because it decides whether this pattern fits:

| | |
|---|---|
| **Buys** | Share with anyone, instantly. No accounts, no invites, no directory. |
| **Costs** | Anyone with the URL is authorised. No per-recipient revocation — rotating `SITE_TOKEN` revokes *everyone*. No audit trail of who read what. |

Correct for a small, trusted audience. Wrong the moment you need to know who
read something, or to remove one person's access.

## What makes it hold

The token is only as good as its containment, so three response headers are
security controls rather than hygiene:

- **`Referrer-Policy: no-referrer`** — archive content contains outbound links.
  Without this, clicking one sends the current URL — token included — as the
  `Referer` to a third party. This is the most likely leak in practice, and it
  needs no attacker.
- **`Cache-Control: private, no-store`** — the secret is *in the URL*, so any
  shared cache would key private content on it and serve it onward.
- **`X-Robots-Tag: noindex, nofollow`** — for crawlers that ignore `robots.txt`.

Two further decisions in `worker.js`:

- **Constant-time comparison.** `a === b` short-circuits at the first differing
  byte, so response timing leaks a prefix. Both sides are hashed to a fixed
  length, then compared with `timingSafeEqual`.
- **Indistinguishable 404s.** A wrong token, an unknown path, and a missing
  record return identical responses. A `403` would confirm the path is real and
  worth attacking.

  The ingest endpoint deliberately makes the *opposite* choice and returns
  `401` — it serves a machine we control, where a clear error beats concealment.
  Concealment is only worth its debugging cost on the path strangers can reach.

- **Fails closed.** If either secret is unset the Worker refuses everything. A
  broken deploy beats a silently public archive.

Two secrets, two audiences, so a leaked reader link never grants write access:
`SITE_TOKEN` (reader, in the path) and `INGEST_KEY` (publisher, in a header).

## Deploy

```bash
wrangler d1 create capability-archive     # paste the id into wrangler.jsonc
wrangler d1 execute capability-archive --file schema.sql
wrangler deploy
wrangler secret put SITE_TOKEN            # openssl rand -hex 32
wrangler secret put INGEST_KEY            # openssl rand -hex 32
```

## Rotation

Independent by design — rotating one never affects the other.

- `SITE_TOKEN`: `wrangler secret put SITE_TOKEN`, then share the new URL. The
  old one 404s as though it never existed.
- `INGEST_KEY`: update the Worker and the publisher. Until both match, ingest
  fails closed with `401` — no window where old and new both work.
