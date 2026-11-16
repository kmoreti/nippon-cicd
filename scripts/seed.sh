#!/usr/bin/env bash
# ============================================================================
# NIPON CI/CD — seed.sh
#
# Run from the host after `docker compose up -d`. Idempotently:
#   1. waits for the Jenkins controller to accept requests,
#   2. makes sure the `nippon-cicd` job exists (creates it from config.xml),
#   3. (re)creates the job's config from the repo's copy,
#   4. kicks an initial build.
#
# Jenkins is on http://localhost:8080 (admin/admin until first login). The
# crumb-protected REST endpoints are used, so a CSRF token is fetched first.
# ============================================================================
set -euo pipefail

JENKINS_URL="${JENKINS_URL:-http://localhost:8080}"
JOB="nippon-cicd"
HERE="$(cd "$(dirname "$0")/.." && pwd)"

echo "=== waiting for Jenkins at ${JENKINS_URL} ==="
for i in $(seq 1 60); do
  if curl -fsS "${JENKINS_URL}/api/json" >/dev/null 2>&1; then
    echo "Jenkins is up (after ~$((i*3))s)"
    break
  fi
  sleep 3
done

# CSRF crumb for state-changing endpoints
CRUMB=$(curl -fsS -c /tmp/jenkins.jar "${JENKINS_URL}/crumbIssuer/api/json" \
  | python3 -c 'import sys,json;d=json.load(sys.stdin);print(d["crumb"] if "crumb" in d else d["crumbRequestField"]+"="+d["crumb"])' 2>/dev/null || echo "")
CRUMB_FIELD=$(curl -fsS -c /tmp/jenkins.jar "${JENKINS_URL}/crumbIssuer/api/json" 2>/dev/null \
  | python3 -c 'import sys,json;print(json.load(sys.stdin).get("crumbRequestField","Jenkins-Crumb"))' 2>/dev/null || echo "Jenkins-Crumb")
echo "crumb field: ${CRUMB_FIELD}"

# 1) Ensure the job exists; create from config.xml if missing.
if ! curl -fsS "${JENKINS_URL}/job/${JOB}/api/json" >/dev/null 2>&1; then
  echo ">>> creating job '${JOB}' from jenkins/jobs/${JOB}/config.xml"
  curl -fsS -b /tmp/jenkins.jar \
    -H "${CRUMB_FIELD}: ${CRUMB}" \
    --data-binary @"${HERE}/jenkins/jobs/${JOB}/config.xml" \
    "${JENKINS_URL}/createItem?name=${JOB}" || echo "(job may already exist)"
else
  echo ">>> job '${JOB}' already exists; updating config"
  curl -fsS -b /tmp/jenkins.jar \
    -H "${CRUMB_FIELD}: ${CRUMB}" \
    --data-binary @"${HERE}/jenkins/jobs/${JOB}/config.xml" \
    "${JENKINS_URL}/job/${JOB}/config.xml" || true
fi

# 2) Kick an initial build (so the pipeline + its credentials get exercised).
echo ">>> triggering initial build of ${JOB}"
curl -fsS -b /tmp/jenkins.jar \
  -H "${CRUMB_FIELD}: ${CRUMB}" \
  -d "NIPON_REF=main&DEPLOY=true&SKIP_TESTS=false" \
  "${JENKINS_URL}/job/${JOB}/buildWithParameters" || echo "(build trigger may need a manual start)"

echo "=== seed complete. Watch: ${JENKINS_URL}/job/${JOB}/"
