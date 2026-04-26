#!/usr/bin/env bash

REGION="${REGION?Please set the REGION environment variable to a GCP region (e.g. us-central1)}"
DEVSHELL_PROJECT_ID="${DEVSHELL_PROJECT_ID:-$(gcloud config get-value project 2>/dev/null)}"

gcloud container --project "$DEVSHELL_PROJECT_ID" clusters create-auto autopilot-cluster-1 \
  --region "$REGION" \
  --release-channel regular \
  --network "projects/$DEVSHELL_PROJECT_ID/global/networks/default" \
  --subnetwork "projects/$DEVSHELL_PROJECT_ID/regions/$REGION/subnetworks/default" \
  --cluster-ipv4-cidr /17 \
  --binauthz-evaluation-mode=DISABLED
