# The primary zone. Alias zones are created the same way and passed into the
# same modules -- see the alias_zones resource below.
resource "cloudflare_zone" "primary" {
  name = var.base_domain
  account = {
    id = var.account_id
  }
}

resource "cloudflare_zone" "alias" {
  for_each = toset(var.alias_domains)

  name = each.value
  account = {
    id = var.account_id
  }
}

module "access" {
  source     = "./modules/access"
  account_id = var.account_id

  base_domain              = var.base_domain
  alias_domains            = var.alias_domains
  team_name                = var.team_name
  allowed_idp_ids          = var.allowed_idp_ids
  admin_emails             = var.admin_emails
  public_bypass_subdomains = var.public_bypass_subdomains
}

module "tunnel" {
  source     = "./modules/tunnel"
  account_id = var.account_id

  name           = "${var.base_domain}-tunnel"
  base_domain    = var.base_domain
  alias_domains  = var.alias_domains
  app_subdomains = var.app_subdomains
  origin_url     = var.origin_url
  private_subnet = var.private_subnet
}

module "dns_primary" {
  source  = "./modules/dns"
  zone_id = cloudflare_zone.primary.id

  tunnel_subdomains   = var.app_subdomains
  tunnel_cname_target = module.tunnel.cname_target
}

# SECURITY -- do not remove the depends_on.
#
# These records are what make the internal apps resolvable on the alias domain.
# Access matches on HOSTNAME: the *.${base_domain} wildcard app does not cover
# an alias domain, so the mirrored apps in modules/access are the only thing
# authenticating these hostnames.
#
# Terraform does not order independent resources. Without this, DNS can be
# created before the mirror apps exist, and for that window every app behind the
# tunnel is reachable with no authentication at all. The dependency is not
# implied by any argument reference, so it has to be stated.
module "dns_alias" {
  for_each = cloudflare_zone.alias

  source  = "./modules/dns"
  zone_id = each.value.id

  tunnel_subdomains   = var.app_subdomains
  tunnel_cname_target = module.tunnel.cname_target

  depends_on = [module.access]
}

# security.txt for every zone, primary and alias alike. One for_each is the
# single place that answers "which zones publish a security policy".
module "security_txt" {
  source = "./modules/security_txt"

  for_each = merge(
    { (var.base_domain) = cloudflare_zone.primary.id },
    { for d, z in cloudflare_zone.alias : d => z.id },
  )

  zone_id              = each.value
  domain               = each.key
  contacts             = local.security_txt_contacts
  expires              = var.security_txt_expires
  cloudflare_api_token = var.cloudflare_api_token
}
