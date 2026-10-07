#!/bin/bash
# Deploys the site to a GCS bucket configured for static website hosting.
# Usage: site/deploy.sh <bucket-name>
# Optional: GCLOUD_ACCOUNT and GCLOUD_PROJECT select credentials without
# changing the active gcloud configuration.
#
# One-time bucket setup (public static site):
#   gsutil mb -l us-central1 gs://<bucket>
#   gsutil iam ch allUsers:objectViewer gs://<bucket>
#   gsutil web set -m index.html gs://<bucket>
# Then front it with a load balancer + managed cert for a custom domain,
# or serve directly via https://storage.googleapis.com/<bucket>/index.html.
set -euo pipefail

BUCKET="${1:?usage: site/deploy.sh <bucket-name>}"
cd "$(dirname "$0")"

GCLOUD=(gcloud)
if [[ -n "${GCLOUD_ACCOUNT:-}" ]]; then
  GCLOUD+=(--account="$GCLOUD_ACCOUNT")
fi
if [[ -n "${GCLOUD_PROJECT:-}" ]]; then
  GCLOUD+=(--project="$GCLOUD_PROJECT")
fi

# Upload only site assets, then HTML. Never sync/delete the bucket:
# appcast.json belongs to the release workflow and must remain untouched.
"${GCLOUD[@]}" storage cp --cache-control="public, max-age=86400" img/*.png "gs://${BUCKET}/img/"
"${GCLOUD[@]}" storage cp --cache-control="no-cache" style.css "gs://${BUCKET}/style.css"
"${GCLOUD[@]}" storage cp --cache-control="no-cache" index.html "gs://${BUCKET}/index.html"

echo "Deployed: https://storage.googleapis.com/${BUCKET}/index.html"
