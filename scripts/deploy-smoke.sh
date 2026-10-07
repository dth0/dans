#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repository=$(CDPATH= cd -- "$script_dir/.." && pwd)
temporary=$(mktemp -d "${TMPDIR:-/tmp}/dans-deploy-smoke.XXXXXX")
trap 'rm -rf "$temporary"' EXIT HUP INT TERM

if grep -Fq 'powerdns:8081/api/v1' "$repository/deploy/README.md" ||
	grep -Fq 'powerdns-api.powerdns.svc.cluster.local:8081/api/v1' "$repository/deploy/kubernetes/dans.yaml"; then
	printf '%s\n' 'deployment smoke: DANS_POWERDNS_URL must be a PowerDNS origin without /api/v1' >&2
	exit 1
fi

for secret in database-url powerdns-api-key redis-url redis-users.acl tls.crt tls.key; do
	printf 'smoke\n' >"$temporary/$secret"
done

DANS_IMAGE=dans:smoke \
DANS_POWERDNS_URL=http://powerdns:8081 \
DANS_DATABASE_SECRET_FILE="$temporary/database-url" \
DANS_POWERDNS_SECRET_FILE="$temporary/powerdns-api-key" \
DANS_REDIS_URL_SECRET_FILE="$temporary/redis-url" \
DANS_REDIS_ACL_FILE="$temporary/redis-users.acl" \
DANS_TLS_CERT_FILE="$temporary/tls.crt" \
DANS_TLS_KEY_FILE="$temporary/tls.key" \
	docker compose --file "$repository/deploy/docker/compose.yaml" config --quiet

kubectl kustomize "$repository/deploy/kubernetes" >/dev/null
