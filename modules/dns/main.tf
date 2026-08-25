terraform {
  required_providers {
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 5.0"
    }
  }
}

variable "zone_id" { type = string }

variable "tunnel_subdomains" {
  description = "Subdomains that CNAME to the tunnel. Same list that drives ingress -- see modules/tunnel."
  type        = list(string)
  default     = []
}

variable "tunnel_cname_target" {
  description = "<tunnel-id>.cfargotunnel.com"
  type        = string
}

variable "extra_records" {
  description = "Records outside the tunnel profile (apex, mail, verification TXT)."
  type = map(object({
    name    = string
    type    = string
    content = string
    proxied = bool
    ttl     = number
  }))
  default = {}
}

# Proxied CNAMEs to the tunnel. Proxied is required, not stylistic: an
# unproxied record would expose the cfargotunnel target directly and skip the
# edge entirely -- which is also where Access runs.
resource "cloudflare_dns_record" "tunnel" {
  for_each = toset(var.tunnel_subdomains)

  zone_id = var.zone_id
  name    = each.value
  type    = "CNAME"
  content = var.tunnel_cname_target
  proxied = true
  ttl     = 1
}

resource "cloudflare_dns_record" "extra" {
  for_each = var.extra_records

  zone_id = var.zone_id
  name    = each.value.name
  type    = each.value.type
  content = each.value.content
  proxied = each.value.proxied
  ttl     = each.value.ttl
}
