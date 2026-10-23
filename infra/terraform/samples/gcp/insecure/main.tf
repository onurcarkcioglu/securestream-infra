# DELIBERATELY INSECURE - scan target only. Never run terraform init/plan/apply here.
# Findings expected: bucket readable by allUsers, firewall open to the internet, VM on the default service account.
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
  name     = "securestream-sample-media-insecure"
  location = "EU"
}

resource "google_storage_bucket_iam_member" "public_read" {
  bucket = google_storage_bucket.media.name
  role   = "roles/storage.objectViewer"
  member = "allUsers"
}

resource "google_compute_firewall" "ssh" {
  name          = "sample-allow-ssh-insecure"
  network       = "default"
  source_ranges = ["0.0.0.0/0"]

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }
}

data "google_compute_default_service_account" "default" {}

resource "google_compute_instance" "worker" {
  name         = "sample-worker-insecure"
  machine_type = "e2-small"
  zone         = "europe-west3-a"

  boot_disk {
    initialize_params {
      image = "debian-cloud/debian-12"
    }
  }

  network_interface {
    network = "default"
    access_config {}
  }

  service_account {
    email  = data.google_compute_default_service_account.default.email
    scopes = ["cloud-platform"]
  }
}
