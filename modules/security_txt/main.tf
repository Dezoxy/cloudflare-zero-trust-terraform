# --- Working around a provider gap, idempotently ---------------------------
#
# Cloudflare serves /.well-known/security.txt (RFC 9116) from the edge via
# Security Center, for any zone, regardless of what origin sits behind it. The
# Terraform provider exposes no resource for that endpoint.
#
# The usual reaction is a null_resource with a local-exec that re-runs on every
# apply. That is worse than not managing it: the apply is never a no-op, so a
# clean plan stops meaning anything.
#
# This does it properly instead:
#
#   * terraform_data, not null_resource -- built in, so the module needs no
#     provider of its own.
#   * triggers_replace on a HASH OF THE PAYLOAD, so the PUT re-runs when, and
#     only when, the content actually changes. Same inputs => empty plan.
#   * the API call is a PUT, which is idempotent, so a retried apply converges
#     rather than duplicating.
#
# The honest trade-off, stated because a reviewer will spot it anyway: a
# provisioner is imperative, has no drift detection, and cannot see a change
# made in the dashboard. It is the right tool ONLY while the provider lacks a
# resource. When one lands, this module should be deleted and imported.

variable "zone_id" { type = string }
variable "domain" { type = string }
variable "contacts" { type = list(string) }
variable "expires" { type = string }

variable "preferred_languages" {
  type    = string
  default = "en"
}

variable "cloudflare_api_token" {
  type      = string
  sensitive = true
}

locals {
  payload = {
    enabled             = true
    contact             = var.contacts
    expires             = var.expires
    preferred_languages = var.preferred_languages
    canonical           = ["https://${var.domain}/.well-known/security.txt"]
  }

  payload_hash = sha256(jsonencode(local.payload))
}

resource "terraform_data" "security_txt" {
  triggers_replace = [var.zone_id, local.payload_hash]

  input = {
    domain       = var.domain
    payload_hash = local.payload_hash
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]

    # The token goes in the environment, never on the command line -- argv is
    # world-readable via ps on most systems.
    environment = {
      CLOUDFLARE_API_TOKEN = var.cloudflare_api_token
    }

    command = <<-EOT
      set -euo pipefail
      curl --fail --silent --show-error --output /dev/null \
        --request PUT \
        "https://api.cloudflare.com/client/v4/zones/${var.zone_id}/security-center/securitytxt" \
        --header "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
        --header "Content-Type: application/json" \
        --data @- <<'JSON'
      ${jsonencode(local.payload)}
      JSON
    EOT
  }
}

output "policy_url" {
  value = "https://${var.domain}/.well-known/security.txt"
}
