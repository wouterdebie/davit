#!/bin/bash
# Deploys the site to a GCS bucket configured for static website hosting.
# Usage: site/deploy.sh <bucket-name>
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

gsutil -m rsync -r -d -x 'deploy\.sh$' . "gs://${BUCKET}"
# Sensible cache headers: short for HTML, long for images.
gsutil -m setmeta -h "Cache-Control:public, max-age=300" "gs://${BUCKET}/index.html"
gsutil -m setmeta -h "Cache-Control:public, max-age=86400" "gs://${BUCKET}/img/*" 2>/dev/null || true

echo "Deployed: https://storage.googleapis.com/${BUCKET}/index.html"
