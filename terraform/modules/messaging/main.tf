variable "topic_name" {
  type    = string
  default = "evaluation-events"
}

variable "subscription_name" {
  type    = string
  default = "evaluation-events-sub"
}

variable "ack_deadline_seconds" {
  type    = number
  default = 30
}

resource "google_pubsub_topic" "evaluation_events" {
  name = var.topic_name
}

resource "google_pubsub_topic" "dead_letter" {
  name = "${var.topic_name}-dlq"
}

resource "google_pubsub_subscription" "evaluation_events" {
  name  = var.subscription_name
  topic = google_pubsub_topic.evaluation_events.name

  ack_deadline_seconds = var.ack_deadline_seconds

  dead_letter_policy {
    dead_letter_topic     = google_pubsub_topic.dead_letter.id
    max_delivery_attempts = 5
  }

  retry_policy {
    minimum_backoff = "10s"
    maximum_backoff = "600s"
  }

  expiration_policy {
    ttl = ""
  }
}

data "google_project" "this" {}

locals {
  pubsub_agent = "serviceAccount:service-${data.google_project.this.number}@gcp-sa-pubsub.iam.gserviceaccount.com"
}

resource "google_pubsub_topic_iam_member" "dlq_publisher" {
  topic  = google_pubsub_topic.dead_letter.name
  role   = "roles/pubsub.publisher"
  member = local.pubsub_agent
}

resource "google_pubsub_subscription_iam_member" "dlq_subscriber" {
  subscription = google_pubsub_subscription.evaluation_events.name
  role         = "roles/pubsub.subscriber"
  member       = local.pubsub_agent
}

output "topic_name" {
  value = google_pubsub_topic.evaluation_events.name
}

output "subscription_name" {
  value = google_pubsub_subscription.evaluation_events.name
}

output "dead_letter_topic_name" {
  value = google_pubsub_topic.dead_letter.name
}
