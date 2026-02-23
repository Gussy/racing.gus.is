output "droplet_ip" {
  description = "Public IPv4 address of the droplet"
  value       = var.create_droplet ? digitalocean_droplet.racing[0].ipv4_address : null
}

output "droplet_id" {
  description = "ID of the droplet"
  value       = var.create_droplet ? digitalocean_droplet.racing[0].id : null
}

output "volume_id" {
  description = "ID of the persistent data volume"
  value       = digitalocean_volume.data.id
}
