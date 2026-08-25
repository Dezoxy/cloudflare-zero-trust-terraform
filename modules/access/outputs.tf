output "wildcard_app_ids" {
  description = "Access application ID per protected domain."
  value       = { for d, a in cloudflare_zero_trust_access_application.wildcard : d => a.id }
}

output "wildcard_app_auds" {
  description = "AUD tag per protected domain. An origin verifying the Access JWT needs its app's AUD."
  value       = { for d, a in cloudflare_zero_trust_access_application.wildcard : d => a.aud }
}
