# Secure counterpart of ../insecure: same resources, configured correctly. Scan target only.
terraform {
  required_providers {
    google = { source = "hashicorp/google", version = "~> 7.0" }
  }
}

provider "google" {
  project = "securestream-sample"
  region  = "europe-west3"
}

resource "google_storage_bucket" "media" {
  name                        = "securestream-sample-media-secure"
  location                    = "EU"
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"

  versioning {
    enabled = true
  }

  logging {
    log_bucket = "securestream-sample-access-logs"
  }
}

resource "google_storage_bucket_iam_member" "reader" {
  bucket = google_storage_bucket.media.name
  role   = "roles/storage.objectViewer"
  member = "serviceAccount:${google_service_account.worker.email}"
}

resource "google_compute_network" "lab" {
  name                    = "sample-lab-secure"
  auto_create_subnetworks = false
}

resource "google_compute_firewall" "ssh" {
  name          = "sample-allow-ssh-iap"
  network       = google_compute_network.lab.name
  source_ranges = ["35.235.240.0/20"] # Identity-Aware Proxy TCP forwarding only

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }
}

resource "google_service_account" "worker" {
  account_id   = "sample-worker"
  display_name = "Least-privilege identity for the sample worker VM"
}

resource "google_compute_instance" "worker" {
  name         = "sample-worker-secure"
  machine_type = "e2-small"
  zone         = "europe-west3-a"

  boot_disk {
    kms_key_self_link = "projects/securestream-sample/locations/europe-west3/keyRings/lab/cryptoKeys/disks"
    initialize_params {
      image = "debian-cloud/debian-12"
    }
  }

  network_interface {
    subnetwork = "projects/securestream-sample/regions/europe-west3/subnetworks/lab"
  }

  metadata = {
    block-project-ssh-keys = "true"
    enable-oslogin         = "TRUE"
  }

  shielded_instance_config {
    enable_secure_boot          = true
    enable_vtpm                 = true
    enable_integrity_monitoring = true
  }

  service_account {
    email  = google_service_account.worker.email
    scopes = ["cloud-platform"]
  }
}
