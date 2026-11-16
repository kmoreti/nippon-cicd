#!/usr/bin/env bash
# ============================================================================
# NIPON CI/CD — bootstrap-plugins.sh
#
# The jenkins/jenkins:lts-jdk21 image ships with ZERO plugins, and this LAN has
# no public update-center at boot time, so we install the pipeline's plugins
# through the bundled jenkins-cli.jar (which talks to the now-reachable update
# center). Jenkins restarts itself after each install; we wait for it to come
# back up before creating the job.
#
#   ./scripts/bootstrap-plugins.sh
# ============================================================================
set -uo pipefail

JENKINS_URL="${JENKINS_URL:-http://localhost:8080}"
AUTH="${JENKINS_AUTH:-admin:admin}"
CLI="/usr/share/jenkins/jenkins-cli.jar"
# Core plugins the declarative pipeline needs. workflow-aggregator pulls the
# workflow-cps/job/durable-task/basic-steps chain; pipeline-input-step for `input`.
PLUGINS=(git workflow-aggregator pipeline-input-step)

wait_jenkins() {
  for i in $(seq 1 90); do
    code=$(curl -s -o /dev/null -w '%{http_code}' "${JENKINS_URL}/login" 2>/dev/null || echo 000)
    if [ "$code" = "200" ]; then return 0; fi
    sleep 2
  done
  return 1
}

echo "=== waiting for Jenkins ==="
wait_jenkins || { echo "Jenkins did not come up"; exit 1; }

installed() {
  # returns list of already-installed plugin ids
  docker exec nippon-jenkins bash -c "ls /var/jenkins_home/plugins/ 2>/dev/null | sed -E 's/\.jpi$//;s/\.hpi$//'"
}

have=0
for p in "${PLUGINS[@]}"; do
  if docker exec nippon-jenkins bash -c "ls /var/jenkins_home/plugins/ 2>/dev/null | grep -qx '${p}.jpi'"; then
    echo "  ${p}: already installed"
    have=$((have+1))
    continue
  fi
  echo "  ${p}: installing via jenkins-cli.jar ..."
  docker exec nippon-jenkins java -jar "$CLI" -s "$JENKINS_URL" -auth "$AUTH" \
    install-plugin "$p" 2>&1 | grep -v -iE 'gho_' | tail -3
  echo "  ${p}: restarting Jenkins (install triggers a restart) ..."
  wait_jenkins || echo "  WARNING: Jenkins did not come back after installing ${p}"
done

echo "=== installed plugins ==="
docker exec nippon-jenkins bash -c "ls /var/jenkins_home/plugins/ 2>/dev/null | sed -E 's/\.jpi$//' | sort | tr '\n' ' '"
echo
echo "=== plugin bootstrap done ==="
