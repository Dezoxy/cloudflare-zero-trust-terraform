# Cloudflare Zero Trust, as code

Terraform for a multi-domain Cloudflare Zero Trust estate: Access applications
and policies, a Tunnel to a private origin, DNS, and `security.txt` — with
secrets brokered from Azure Key Vault through GitHub OIDC, so the pipeline holds
no long-lived credential.

It is a reference extract rather than a starter template: a distilled version of
a setup that has run a real multi-zone account for some time. The point is the
handful of decisions below, each of which cost something to learn.

```
.
├── main.tf                      # zones + module wiring
├── variables.tf                 # inputs (no identity value has a default -- see §5)
├── modules/
│   ├── access/                  # §1 wildcard apps + alias mirrors
│   ├── tunnel/                  # §2 single-source ingress fan-out
│   ├── dns/                     #    proxied CNAMEs to the tunnel
│   └── security_txt/            # §3 working around a provider gap
├── .github/
│   ├── actions/azure-secrets/   # §4 OIDC -> Key Vault
│   └── workflows/
└── workers/capability-archive/  # §6 auth without a login form
```

---

## 1. Access matches on hostname, so dual-homing silently disables it

The failure this repo is built around.

Serve the same internal apps on two domains — `app.example.com` and
`app.example.net` reaching the same origin through the same tunnel — and a
wildcard Access application on `*.example.com` protects the second domain **not
at all**. Same apps, same origin, no authentication.

Nothing errors. The dashboards load. They just load for anyone who knows the
name.

So [`modules/access`](modules/access/main.tf) creates every application once per
domain, sharing policies across the mirrors — an alias is the same trust
boundary reached by a different name, not a new one. Two details that matter:

- The mirrors are **separate resources**, not a widened `for_each` over the
  originals. Changing an existing resource's address would destroy and recreate
  the live application, issuing a new AUD and logging everyone out, for no gain.
- Alias DNS carries an explicit **`depends_on = [module.access]`**
  ([`main.tf`](main.tf)). Terraform does not order independent resources, and
  the dependency is not implied by any argument reference. Without it, DNS can
  be created before the mirrored apps exist — and for that window every app
  behind the tunnel is reachable unauthenticated.

## 2. One list, three fan-outs

`app_subdomains` is the only list an operator edits. From it,
[`modules/tunnel`](modules/tunnel/main.tf) builds (subdomains × domains) ingress
rules, [`modules/dns`](modules/dns/main.tf) builds the matching CNAME in every
zone, and the wildcard Access app already covers the hostnames.

Adding `"grafana"` yields ingress, DNS, and authentication on every domain, with
no chance of the three drifting apart — the failure mode when each lives in its
own file.

The half that is deliberately *not* here: the reverse proxy routes by `Host`
header, so its config must accept the new hostname too. That is config
management, not Terraform. Until it lands the hostname resolves and the proxy
returns `404` — failing closed and visibly, rather than serving the wrong app.

## 3. A provisioner that is still idempotent

Cloudflare serves `/.well-known/security.txt` (RFC 9116) from the edge for any
zone. The provider exposes no resource for it.

The reflex is a `null_resource` with a `local-exec` that re-runs on every apply
— worse than not managing it at all, because the apply is never a no-op and a
clean plan stops meaning anything.

[`modules/security_txt`](modules/security_txt/main.tf) instead uses
`terraform_data` with `triggers_replace` on a **hash of the payload**, so the
`PUT` re-runs when and only when the content changes. Same inputs, empty plan.

The honest limitation, stated because a reviewer will spot it: a provisioner is
imperative, has no drift detection, and cannot see a dashboard edit. It is
correct *only* while the provider lacks a resource. When one lands, this module
should be deleted and imported.

## 4. No long-lived credentials in CI

[`.github/actions/azure-secrets`](.github/actions/azure-secrets/action.yml)
exchanges the workflow's OIDC token for an Azure token and pulls secrets from
Key Vault at runtime. GitHub stores only non-secret repository *variables*
(vault name, client/tenant/subscription IDs).

Nothing to rotate in GitHub, nothing for a fork to exfiltrate, and access is
revocable in one place — the federated credential on the Entra app, scoped to
this repository and ref. Each secret carries an `envvar` tag naming the variable
to restore it to, so the vault owns the mapping and the action stays generic.

Values are masked *before* export; otherwise a secret echoed by any later step
lands in a public build log verbatim.

## 5. Identity values have no defaults

An email address is personal data. Baking a real one into a `default` publishes
it to everyone who clones the repo, and git history makes that permanent — a
later cleanup commit does not help, because the old blob stays reachable.

So `admin_emails` has no default and the config will not plan without it. The
same rule covers anything describing a physical location: a home WAN IP
annotated with "port 8080 forwards to the controller" is a port map of someone's
house, not configuration.

This is the cheapest possible control and it is enforced by the type system
rather than by discipline.

## 6. Authentication without a login form

[`workers/capability-archive`](workers/capability-archive/) is the worked
example of a **public bypass** — a hostname carved out of the wildcard Access
app, which therefore has to carry its own authentication.

It uses a capability link: an unguessable token in the URL path *is* the
credential. Access cannot front it, because a legitimate link-holder has no
Access identity to present. That buys frictionless sharing and costs
per-recipient revocation.

Its README covers the parts that make it hold: `Referrer-Policy: no-referrer` as
a load-bearing control rather than hygiene, constant-time comparison,
indistinguishable `404`s on the reader path (and a deliberately *distinguishable*
`401` on the machine path), and failing closed when a secret is unset.

---

## Running it

```bash
cp terraform.tfvars.example terraform.tfvars   # gitignored
terraform init
terraform plan
```

Validate without credentials or network:

```bash
terraform init -backend=false && terraform validate
```

State configuration is intentionally omitted — add the backend your environment
uses. The CI workflow assumes remote state with locking; two concurrent applies
against local state is how state gets orphaned.

## Notes

- Provider `cloudflare ~> 5.0`. Note the v5 idiom: `include` on an Access policy
  is an **attribute** (a list), not a repeatable block, so it is built with a
  comprehension rather than `dynamic`. This trips up anyone porting v4 config.
- Domains, IDs, and addresses throughout are placeholders.
- Not covered here, to keep the repo readable: Gateway DNS/L4 policies, WARP
  device profiles, per-zone mail (SPF/DKIM/DMARC), and Workers custom domains.
