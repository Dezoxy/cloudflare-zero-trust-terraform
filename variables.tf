# No identity value in this file has a default.
#
# That is deliberate, and it is the single most important convention here. An
# email address is personal data: baking a real one into a `default` publishes
# it to everyone who ever clones the repo, and git history makes that permanent.
# Requiring the operator to supply them keeps the config publishable and forces
# the values through the secret path (see scripts/dev/azure_kv_run.sh) rather
# than into a commit.
#
# The same rule applies to anything that describes a physical location: a home
# WAN IP annotated with "port 8080 forwards to the controller" is a port map of
# someone's house, not configuration.

variable "cloudflare_api_token" {
  description = "Cloudflare API token with Zero Trust and Zone permissions."
  type        = string
  sensitive   = true
}

variable "account_id" {
  description = "Cloudflare account ID."
  type        = string
}

variable "base_domain" {
  description = "Primary zone name, e.g. example.com."
  type        = string
}

variable "alias_domains" {
  description = <<-DESC
    Additional zones the same internal apps answer on (dual-homing). Every entry
    fans out to Tunnel ingress rules, DNS records, AND mirrored Access
    applications. Read the comment at the top of modules/access/access_apps.tf
    before adding one: DNS without a matching Access app publishes every app
    unauthenticated.
  DESC
  type        = list(string)
  default     = []
}

variable "app_subdomains" {
  description = "Subdomains routed through the Tunnel to the reverse-proxy origin. The single source of truth for both ingress rules and DNS records."
  type        = list(string)
  default     = []
}

variable "origin_url" {
  description = "Origin the Tunnel forwards app hostnames to. Host-header routing happens on the origin, not at the edge."
  type        = string
  default     = "https://reverse-proxy.internal:443"
}

variable "private_subnet" {
  description = "Private CIDR advertised through the Tunnel for WARP clients."
  type        = string
  default     = "10.10.0.0/24"

  validation {
    condition     = can(cidrhost(var.private_subnet, 0))
    error_message = "private_subnet must be a valid IPv4 or IPv6 CIDR block."
  }
}

variable "team_name" {
  description = "Access team name (the subdomain in <team>.cloudflareaccess.com)."
  type        = string
}

variable "allowed_idp_ids" {
  description = "Identity provider IDs permitted on Access applications."
  type        = list(string)
}

variable "admin_emails" {
  description = "Administrator email addresses. No default -- see the note at the top of this file."
  type        = list(string)

  validation {
    condition     = length(var.admin_emails) > 0
    error_message = "At least one admin email is required, or nobody can reach the apps."
  }
}

variable "public_bypass_subdomains" {
  description = <<-DESC
    Subdomains carved OUT of the wildcard Access app and served publicly. Each
    entry is a deliberate hole in the perimeter, so each one needs its own
    authentication story -- a capability token, mTLS, a service token, or
    application-level auth. See workers/capability-archive for a worked example.
  DESC
  type        = list(string)
  default     = []
}

variable "security_txt_contacts" {
  description = "RFC 9116 contact URIs. Defaults to mailto: entries derived from admin_emails."
  type        = list(string)
  default     = []

  validation {
    condition = alltrue([
      for c in var.security_txt_contacts :
      startswith(c, "mailto:") || startswith(c, "tel:") || startswith(c, "https://")
    ])
    error_message = "security_txt_contacts entries must start with mailto:, tel:, or https://."
  }
}

variable "security_txt_expires" {
  description = <<-DESC
    RFC 9116 Expires, as a static RFC3339 UTC timestamp. Static on purpose: a
    computed timestamp() would change the payload hash on every plan and produce
    a permanent diff. See .github/workflows/security-txt-bump.yml for how it is
    kept from lapsing.
  DESC
  type        = string

  validation {
    condition     = can(regex("^\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2}Z$", var.security_txt_expires))
    error_message = "security_txt_expires must be RFC3339 UTC, e.g. 2027-04-21T00:00:00Z."
  }
}
