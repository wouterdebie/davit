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

# appcast.json is published by the release workflow (.github/workflows/
# release.yml), not by this site deploy — exclude it so a site deploy never
# clobbers it with a stale copy. (-x excludes it from both upload AND -d
# deletion, so the release-managed object is left untouched.)
gsutil -m rsync -r -d -x '(deploy\.sh|appcast\.json)$' . "gs://${BUCKET}"
# Cache headers: HTML revalidates every visit (instant deploys), images cache a day.
gsutil -m setmeta -h "Cache-Control:no-cache" "gs://${BUCKET}/index.html"
gsutil -m setmeta -h "Cache-Control:public, max-age=86400" "gs://${BUCKET}/img/*" 2>/dev/null || true

echo "Deployed: https://storage.googleapis.com/${BUCKET}/index.html"
