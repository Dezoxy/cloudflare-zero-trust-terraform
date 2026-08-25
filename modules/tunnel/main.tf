terraform {
  required_providers {
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 5.0"
    }
  }
}

variable "account_id" { type = string }
variable "name" { type = string }
variable "base_domain" { type = string }
variable "alias_domains" {
  type    = list(string)
  default = []
}
variable "app_subdomains" { type = list(string) }
variable "origin_url" { type = string }
variable "private_subnet" { type = string }

variable "direct_ingress_rules" {
  description = "hostname => origin URL for services that bypass the reverse proxy entirely (an API with its own TLS, say). Matched BEFORE the proxy-derived rules."
  type        = map(string)
  default     = {}
}

resource "cloudflare_zero_trust_tunnel_cloudflared" "this" {
  account_id = var.account_id
  name       = var.name
  config_src = "cloudflare"
}

# --- Single-source fan-out -------------------------------------------------
#
# app_subdomains is the ONE list an operator edits. From it:
#
#   * this file builds (subdomains x domains) ingress rules
#   * modules/dns builds the matching CNAME per zone
#   * modules/access already covers the hostnames via its wildcard app
#
# Adding "grafana" to that list therefore produces ingress + DNS on every
# domain, and inherits authentication, without touching three files and
# without any chance of the three drifting apart.
#
# The one half that does NOT live here: the reverse proxy on the origin routes
# by Host header, so its router config must accept the new hostname too. That
# is a different system (config management, not Terraform). Until it lands, the
# hostname resolves and the proxy returns 404 -- which is the correct failure
# mode. It fails closed, visibly, rather than serving the wrong app.
locals {
  ingress_domains = concat([var.base_domain], var.alias_domains)

  direct_rules = [
    for hostname, service in var.direct_ingress_rules :
    { hostname = hostname, service = service }
  ]

  proxy_rules = flatten([
    for domain in local.ingress_domains : [
      for sub in var.app_subdomains :
      { hostname = "${sub}.${domain}", service = var.origin_url }
    ]
  ])

  # Direct rules first (most specific), then the proxy fan-out, then a
  # catch-all. cloudflared evaluates in order and requires a terminal rule.
  ingress_rules = concat(local.direct_rules, local.proxy_rules)
}

resource "cloudflare_zero_trust_tunnel_cloudflared_config" "this" {
  account_id = var.account_id
  tunnel_id  = cloudflare_zero_trust_tunnel_cloudflared.this.id

  config = {
    ingress = concat(
      local.ingress_rules,
      [{ service = "http_status:404" }],
    )
  }
}

resource "cloudflare_zero_trust_tunnel_cloudflared_virtual_network" "default" {
  account_id         = var.account_id
  name               = "${var.name}-vnet"
  is_default_network = true
}

# Private routing for WARP clients: reaches the subnet directly, without
# publishing a hostname for every internal service.
resource "cloudflare_zero_trust_tunnel_cloudflared_route" "private_subnet" {
  account_id         = var.account_id
  tunnel_id          = cloudflare_zero_trust_tunnel_cloudflared.this.id
  network            = var.private_subnet
  comment            = "private subnet via ${var.name}"
  virtual_network_id = cloudflare_zero_trust_tunnel_cloudflared_virtual_network.default.id
}

output "tunnel_id" {
  value = cloudflare_zero_trust_tunnel_cloudflared.this.id
}

output "cname_target" {
  description = "Every Tunnel-backed hostname CNAMEs here."
  value       = "${cloudflare_zero_trust_tunnel_cloudflared.this.id}.cfargotunnel.com"
}
