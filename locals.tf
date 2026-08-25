locals {
  # Every zone this configuration manages: the primary plus each dual-homed
  # alias. Used to fan security.txt out over all of them.
  all_domains = concat([var.base_domain], var.alias_domains)

  security_txt_contacts = length(var.security_txt_contacts) > 0 ? var.security_txt_contacts : [for e in var.admin_emails : "mailto:${e}"]
}
