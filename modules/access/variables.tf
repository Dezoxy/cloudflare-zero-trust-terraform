variable "account_id" { type = string }
variable "base_domain" { type = string }

variable "alias_domains" {
  description = "Domains that mirror the primary domain's apps. Each gets its own copy of every application below."
  type        = list(string)
  default     = []
}

variable "team_name" { type = string }
variable "allowed_idp_ids" { type = list(string) }
variable "admin_emails" { type = list(string) }

variable "public_bypass_subdomains" {
  description = "Subdomains served publicly, carved out of the wildcard app."
  type        = list(string)
  default     = []
}
