locals {
  prefix = "kthw"

  cidr = {
    k8s = {
      master_nodes = "10.0.0.0/28"
      nodes        = "10.1.0.0/24"
      pods         = "10.2.0.0/16"
      services     = "10.3.0.0/20"
    }
    bastion = "10.4.0.0/28"
    iap     = "35.235.240.0/20"
  }

  vm = {
    k8s_control_plane = {
      machine_type = "t2a-standard-1"
      image        = "debian-cloud/debian-12-arm64"
      ip_address   = [for i in range(1) : "10.0.0.1${i + 1}"]
    }
    k8s_data_plane = {
      machine_type = "t2a-standard-1"
      image        = "debian-cloud/debian-12-arm64"
      ip_address   = [for i in range(2) : "10.1.0.1${i + 1}"]
    }
    bastion = {
      machine_type = "t2a-standard-1"
      image        = "debian-cloud/debian-12-arm64"
      ip_address   = "10.4.0.11"
    }
  }

  network_tags = {
    allow_iap_ssh = "allow-iap-ssh"
  }
}

#===============================================================================
# VPC
#===============================================================================
resource "google_compute_network" "this" {
  name                    = "${local.prefix}-vpc"
  auto_create_subnetworks = false
}

# NAT Gateway
resource "google_compute_router" "outbound_internet_access" {
  name    = "${local.prefix}-router"
  network = google_compute_network.this.self_link
}
resource "google_compute_router_nat" "outbound_internet_access" {
  name                               = "${local.prefix}-nat"
  router                             = google_compute_router.outbound_internet_access.name
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"
}

# Firewall
# Allow Internal Traffic
resource "google_compute_firewall" "internal" {
  name    = "${local.prefix}-internal"
  network = google_compute_network.this.name
  dynamic "allow" {
    for_each = ["tcp", "udp", "icmp"]
    content {
      protocol = allow.value
    }
  }
  source_ranges = [
    local.cidr.k8s.master_nodes,
    local.cidr.k8s.nodes,
    local.cidr.k8s.pods,
    local.cidr.k8s.services,
    local.cidr.bastion,
  ]
}
# Allow SSH from IAP
resource "google_compute_firewall" "allow_iap_ssh" {
  name    = "${local.prefix}-allow-iap-ssh"
  network = google_compute_network.this.name
  allow {
    protocol = "tcp"
    ports    = ["22"]
  }
  source_ranges = [local.cidr.iap]
  target_tags   = [local.network_tags.allow_iap_ssh]
}

# Subnet
# Kubernetes Control Plane
resource "google_compute_subnetwork" "k8s_control_plane" {
  name          = "${local.prefix}-k8s-control-plane"
  network       = google_compute_network.this.self_link
  ip_cidr_range = local.cidr.k8s.master_nodes
}
# Kubernetes Data Plane
resource "google_compute_subnetwork" "k8s_data_plane" {
  name                     = "${local.prefix}-k8s-data-plane"
  network                  = google_compute_network.this.self_link
  ip_cidr_range            = local.cidr.k8s.nodes
  private_ip_google_access = true
  secondary_ip_range {
    range_name    = "pods"
    ip_cidr_range = local.cidr.k8s.pods
  }
  secondary_ip_range {
    range_name    = "services"
    ip_cidr_range = local.cidr.k8s.services
  }
}
# Bastion
resource "google_compute_subnetwork" "bastion" {
  name          = "${local.prefix}-bastion"
  network       = google_compute_network.this.self_link
  ip_cidr_range = local.cidr.bastion
}
#===============================================================================

#===============================================================================
# VM
#===============================================================================
resource "google_service_account" "vm" {
  account_id = "${local.prefix}-vm"
}
resource "google_project_iam_member" "vm" {
  for_each = toset([
    "roles/compute.networkUser",
  ])

  project = data.google_project.this.id
  role    = each.value
  member  = "serviceAccount:${google_service_account.vm.email}"
}

# Control Plane
resource "google_compute_instance" "k8s_control_plane" {
  count        = length(local.vm.k8s_control_plane.ip_address)
  name         = "${local.prefix}-k8s-control-plane-${count.index}"
  machine_type = local.vm.k8s_control_plane.machine_type
  zone         = var.zone
  service_account {
    email  = google_service_account.vm.email
    scopes = ["cloud-platform"]
  }
  boot_disk {
    initialize_params {
      image = local.vm.k8s_control_plane.image
    }
  }
  network_interface {
    network    = google_compute_network.this.name
    subnetwork = google_compute_subnetwork.k8s_control_plane.name
    network_ip = local.vm.k8s_control_plane.ip_address[count.index]
  }
  tags = [local.network_tags.allow_iap_ssh]
  metadata = {
    enable-oslogin = "true"
  }
}

# Data Plane
resource "google_compute_instance" "k8s_data_plane" {
  count        = length(local.vm.k8s_data_plane.ip_address)
  name         = "${local.prefix}-k8s-data-plane-${count.index}"
  machine_type = local.vm.k8s_data_plane.machine_type
  zone         = var.zone
  service_account {
    email  = google_service_account.vm.email
    scopes = ["cloud-platform"]
  }
  boot_disk {
    initialize_params {
      image = local.vm.k8s_data_plane.image
    }
  }
  network_interface {
    network    = google_compute_network.this.name
    subnetwork = google_compute_subnetwork.k8s_data_plane.name
    network_ip = local.vm.k8s_data_plane.ip_address[count.index]
  }
  tags = [local.network_tags.allow_iap_ssh]
  metadata = {
    enable-oslogin = "true"
  }
}

# Bastion
resource "google_compute_instance" "bastion" {
  name         = "${local.prefix}-bastion"
  machine_type = local.vm.bastion.machine_type
  zone         = var.zone
  service_account {
    email  = google_service_account.vm.email
    scopes = ["cloud-platform"]
  }
  boot_disk {
    initialize_params {
      image = local.vm.bastion.image
    }
  }
  network_interface {
    network    = google_compute_network.this.name
    subnetwork = google_compute_subnetwork.bastion.name
    network_ip = local.vm.bastion.ip_address
  }
  tags = [local.network_tags.allow_iap_ssh]
  metadata = {
    enable-oslogin = "true"
  }
}
#===============================================================================
