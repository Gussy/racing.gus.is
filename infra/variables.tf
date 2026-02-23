variable "do_token" {
  description = "DigitalOcean API token"
  type        = string
  sensitive   = true
}

variable "ssh_key_fingerprint" {
  description = "Fingerprint of the SSH key to add to the droplet"
  type        = string
}

variable "region" {
  description = "DigitalOcean region"
  type        = string
  default     = "sfo3"
}

variable "droplet_size" {
  description = "Droplet size slug"
  type        = string
  default     = "s-1vcpu-2gb"
}

variable "droplet_image" {
  description = "Droplet image slug"
  type        = string
  default     = "ubuntu-24-04-x64"
}

variable "allow_public_ssh" {
  description = "Allow SSH on public interface (enable for bootstrap, disable after Tailscale is up)"
  type        = bool
  default     = false
}

variable "volume_size" {
  description = "Size of the persistent data volume in GB"
  type        = number
  default     = 5
}

variable "create_droplet" {
  description = "Whether to create the droplet (set to false to teardown compute while keeping the volume)"
  type        = bool
  default     = true
}
