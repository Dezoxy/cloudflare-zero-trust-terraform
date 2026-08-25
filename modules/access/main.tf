terraform {
  required_providers {
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 5.0"
    }
  }
}

# --- The pattern this module exists to demonstrate -------------------------
#
# Cloudflare Access matches applications on HOSTNAME, not on origin. That one
# fact drives the whole file.
#
# If the same internal apps answer on two domains -- app.example.com and
# app.example.net both reaching the same reverse proxy through the same tunnel
# -- then a wildcard application on *.example.com provides exactly zero
# protection to *.example.net. The apps are identical, the origin is identical,
# and the second hostname is wide open.
#
# This is a quiet failure. Nothing errors. The dashboards load. They just load
# for anyone who knows the name.
#
# So every application here exists once per domain. The mirrors are separate
# resources rather than a widened for_each over the originals, because changing
# an existing resource's address would destroy and recreate the live app --
# issuing a new AUD and logging everyone out -- for no benefit.
#
# The policies are SHARED across mirrors: an alias is the same trust boundary
# reached by a different name, not a new one.

# Note the v5 idiom: `include` is an ATTRIBUTE (a list), not a repeatable
# block, so it is built with a comprehension rather than a `dynamic` block.
# This trips up anyone porting v4 config, where it was a block.
resource "cloudflare_zero_trust_access_group" "admins" {
  account_id = var.account_id
  name       = "admins"

  include = [
    for email in var.admin_emails : { email = { email = email } }
  ]
}

resource "cloudflare_zero_trust_access_policy" "allow_admins" {
  account_id       = var.account_id
  name             = "allow-admins"
  decision         = "allow"
  session_duration = "24h"

  include = [{
    group = { id = cloudflare_zero_trust_access_group.admins.id }
  }]
}

# Paired with every allow policy. Access evaluates policies in precedence
# order, so a terminal deny makes the default posture explicit rather than
# implicit -- if the allow above is ever edited to match nothing, this still
# refuses everyone instead of silently opening up.
resource "cloudflare_zero_trust_access_policy" "deny_everyone" {
  account_id       = var.account_id
  name             = "block-everyone-else"
  decision         = "deny"
  session_duration = "24h"

  include = [{
    everyone = {}
  }]
}

locals {
  # Primary domain plus every alias, each needing an identical set of apps.
  protected_domains = concat([var.base_domain], var.alias_domains)

  # One public carve-out per (domain x subdomain). A single entry in
  # public_bypass_subdomains therefore produces the carve-out on EVERY domain --
  # forgetting the alias copy is precisely the mistake this flattening prevents.
  bypass_apps = {
    for pair in setproduct(local.protected_domains, var.public_bypass_subdomains) :
    "${pair[1]}.${pair[0]}" => {
      domain    = pair[0]
      subdomain = pair[1]
    }
  }
}

# The wildcard app: one per domain, covering every subdomain not claimed by a
# more specific application.
resource "cloudflare_zero_trust_access_application" "wildcard" {
  for_each = toset(local.protected_domains)

  account_id                = var.account_id
  name                      = "${each.value} / apps"
  domain                    = "*.${each.value}"
  type                      = "self_hosted"
  session_duration          = "24h"
  allowed_idps              = var.allowed_idp_ids
  auto_redirect_to_identity = false
  app_launcher_visible      = each.value == var.base_domain

  destinations = [{
    type = "public"
    uri  = "*.${each.value}"
  }]

  policies = [
    {
      id         = cloudflare_zero_trust_access_policy.allow_admins.id
      precedence = 1
    },
    {
      id         = cloudflare_zero_trust_access_policy.deny_everyone.id
      precedence = 2
    },
  ]
}

# Public carve-outs. A more specific hostname beats the wildcard, which is the
# only mechanism that can punch a hole in it.
#
# Every app here is unauthenticated at the edge, so every app here must carry
# its own authentication. workers/capability-archive is the worked example: an
# unguessable token in the URL path IS the credential, which is why it cannot
# sit behind Access -- a legitimate link-holder has no Access identity to
# present.
resource "cloudflare_zero_trust_access_application" "public_bypass" {
  for_each = local.bypass_apps

  account_id                = var.account_id
  name                      = "${each.value.subdomain}.${each.value.domain} (public)"
  domain                    = each.key
  type                      = "self_hosted"
  session_duration          = "24h"
  allowed_idps              = var.allowed_idp_ids
  auto_redirect_to_identity = false
  app_launcher_visible      = false

  destinations = [{
    type = "public"
    uri  = each.key
  }]

  policies = [{
    name       = "bypass-everyone"
    precedence = 1
    decision   = "bypass"
    include    = [{ everyone = {} }]
  }]
}
