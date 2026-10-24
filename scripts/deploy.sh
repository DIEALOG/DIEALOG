#!/usr/bin/env bash
#
# Build and restart the DIEALOG stack on the deployment host.
#
# Secrets are not kept in the repository. They live in a directory outside the
# checkout (DEPLOY_ENV_DIR, by default a sibling "env" directory) holding
# root.env, backend.env and crypto.env, which this script copies into place
# before handing over to Docker Compose.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

# A push to any of the three repositories starts a deploy, and GitHub only
# serialises runs within a single repository, so take a lock before touching
# the containers.
exec 9>"$(dirname "$repo_root")/.deploy.lock"
flock 9

env_dir="${DEPLOY_ENV_DIR:-$(dirname "$repo_root")/env}"

if [ -d "$env_dir" ]; then
  install -m 600 "$env_dir/root.env" .env
  install -m 600 "$env_dir/backend.env" env/backend.env
  install -m 600 "$env_dir/crypto.env" env/crypto.env
fi

for required in .env env/backend.env env/crypto.env; do
  if [ ! -f "$required" ]; then
    echo "missing $required (expected it in $env_dir)" >&2
    exit 1
  fi
done

docker compose up -d --build --remove-orphans

wait_for() {
  local service="$1"
  local port
  port="$(docker compose port "$service" 8080 | awk -F: '{print $NF}')"

  for _ in $(seq 1 45); do
    local code
    code="$(curl -s -o /dev/null -m 3 -w '%{http_code}' "http://127.0.0.1:${port}/swagger/index.html" || true)"
    if [ "$code" = "200" ]; then
      echo "$service is serving on port $port"
      return 0
    fi
    sleep 2
  done

  echo "$service did not come up on port $port within 90s" >&2
  docker compose logs --tail 80 "$service" >&2
  return 1
}

wait_for backend
wait_for crypto
