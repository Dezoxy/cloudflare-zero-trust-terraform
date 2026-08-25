output "zone_id" {
  description = "Zone ID of the primary domain."
  value       = cloudflare_zone.primary.id
}

output "tunnel_id" {
  description = "Tunnel ID, needed by cloudflared on the origin."
  value       = module.tunnel.tunnel_id
}

output "tunnel_cname_target" {
  description = "CNAME target every Tunnel-backed hostname points at."
  value       = module.tunnel.cname_target
}
