# DNS — gus.is domain is imported, not created: tofu import digitalocean_domain.gus_is gus.is
resource "digitalocean_domain" "gus_is" {
  name = "gus.is"

  lifecycle {
    prevent_destroy = true
  }
}

# A record — racing.gus.is points at the droplet when it exists
resource "digitalocean_record" "a" {
  count  = var.create_droplet ? 1 : 0
  domain = digitalocean_domain.gus_is.id
  type   = "A"
  name   = "racing"
  value  = digitalocean_droplet.racing[0].ipv4_address
  ttl    = 300
}

# AAAA record — IPv6
resource "digitalocean_record" "aaaa" {
  count  = var.create_droplet ? 1 : 0
  domain = digitalocean_domain.gus_is.id
  type   = "AAAA"
  name   = "racing"
  value  = digitalocean_droplet.racing[0].ipv6_address
  ttl    = 300
}

# Persistent data volume — survives droplet teardown
resource "digitalocean_volume" "data" {
  name                    = "racing-gus-is-data"
  region                  = var.region
  size                    = var.volume_size
  initial_filesystem_type = "ext4"
  description             = "Persistent data for racing.gus.is (PostgreSQL, Grafana)"
}

resource "digitalocean_droplet" "racing" {
  count  = var.create_droplet ? 1 : 0
  name   = "racing-gus-is"
  region = var.region
  size   = var.droplet_size
  image  = var.droplet_image

  ssh_keys = [var.ssh_key_fingerprint]
  ipv6     = true

  tags = ["racing", "production"]

  volume_ids = [digitalocean_volume.data.id]
}

resource "digitalocean_firewall" "racing" {
  count       = var.create_droplet ? 1 : 0
  name        = "racing-gus-is"
  droplet_ids = [digitalocean_droplet.racing[0].id]

  # SSH — open during bootstrap, then close after Tailscale is up
  dynamic "inbound_rule" {
    for_each = var.allow_public_ssh ? [1] : []
    content {
      protocol         = "tcp"
      port_range       = "22"
      source_addresses = ["0.0.0.0/0", "::/0"]
    }
  }

  # HTTP
  inbound_rule {
    protocol         = "tcp"
    port_range       = "80"
    source_addresses = ["0.0.0.0/0", "::/0"]
  }

  # HTTPS
  inbound_rule {
    protocol         = "tcp"
    port_range       = "443"
    source_addresses = ["0.0.0.0/0", "::/0"]
  }

  # Tailscale WireGuard
  inbound_rule {
    protocol         = "udp"
    port_range       = "41641"
    source_addresses = ["0.0.0.0/0", "::/0"]
  }

  # All outbound
  outbound_rule {
    protocol              = "tcp"
    port_range            = "1-65535"
    destination_addresses = ["0.0.0.0/0", "::/0"]
  }

  outbound_rule {
    protocol              = "udp"
    port_range            = "1-65535"
    destination_addresses = ["0.0.0.0/0", "::/0"]
  }

  outbound_rule {
    protocol              = "icmp"
    destination_addresses = ["0.0.0.0/0", "::/0"]
  }
}
