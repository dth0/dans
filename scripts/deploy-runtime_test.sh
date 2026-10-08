#!/bin/sh
set -eu
umask 077

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
case "${1:-}" in
  postgres:16.14) export POSTGRES_IMAGE=$1 ;;
  *) printf '%s\n' 'usage: scripts/deploy-runtime_test.sh postgres:16.14' >&2; exit 2 ;;
esac
for command in curl dig docker jq openssl; do
  command -v "$command" >/dev/null 2>&1 || {
    printf '%s\n' "deployment test: missing $command" >&2
    exit 2
  }
done

project=dans-deploy-test-$$
work=$(mktemp -d "${TMPDIR:-/tmp}/dans-deploy-test.XXXXXX")
export DANS_DEPLOY_ROOT=$root
export DANS_IMAGE=dans-deploy-test:$project
export DANS_DATABASE_NETWORK=$project-database
export DANS_POWERDNS_NETWORK=$project-powerdns
export DANS_POWERDNS_URL=http://powerdns:8081
export DANS_DATABASE_SECRET_FILE=$work/database-url
export DANS_POWERDNS_SECRET_FILE=$work/powerdns-api-key
export DANS_REDIS_URL_SECRET_FILE=$work/redis-url
export DANS_REDIS_ACL_FILE=$work/redis-users.acl
export DANS_TLS_CERT_FILE=$work/tls.crt
export DANS_TLS_KEY_FILE=$work/tls.key
export DANS_DEPLOY_TLS_PORT=${DANS_DEPLOY_TLS_PORT:-$(( 20000 + $$ % 20000 ))}
export DANS_DEPLOY_DNS_PORT=${DANS_DEPLOY_DNS_PORT:-$(( DANS_DEPLOY_TLS_PORT + 1 ))}
origin=https://localhost:$DANS_DEPLOY_TLS_PORT
log_dir=${DANS_QA_LOG_DIR:-$work/logs}
database_network_created=0
powerdns_network_created=0
image_built=0
completed=0

compose() {
  docker compose --project-name "$project" \
    --file "$root/deploy/docker/compose.yaml" \
    --file "$root/integration/deployment.compose.yaml" "$@"
}
fail() {
  printf '%s\n' "deployment test: $*" >&2
  exit 1
}
mark_phase() {
  if [ -n "${DANS_QA_PHASE_FILE:-}" ]; then
    printf '%s\n' "$1" >"$DANS_QA_PHASE_FILE"
  fi
}
cleanup() {
  status=$?
  if [ "$completed" -ne 1 ] && [ "$status" -eq 0 ]; then status=1; fi
  trap - EXIT HUP INT TERM
  mkdir -p "$log_dir"
  compose logs --no-color >"$log_dir/deployment.log" 2>&1 || true
  compose down --volumes --remove-orphans >/dev/null 2>&1 || status=1
  if [ "$database_network_created" -eq 1 ]; then
    docker network rm "$DANS_DATABASE_NETWORK" >/dev/null 2>&1 || status=1
  fi
  if [ "$powerdns_network_created" -eq 1 ]; then
    docker network rm "$DANS_POWERDNS_NETWORK" >/dev/null 2>&1 || status=1
  fi
  if [ "$image_built" -eq 1 ]; then
    docker image rm "$DANS_IMAGE" >/dev/null 2>&1 || status=1
  fi
  rm -rf "$work"
  exit "$status"
}
trap cleanup EXIT HUP INT TERM
mkdir -p "$log_dir"
printf '%s\n' "$project" >"$log_dir/project"
printf '%s\n' "$work" >"$log_dir/work-dir"

wait_for() {
  deadline=$(( $(date +%s) + 90 ))
  while [ "$(date +%s)" -le "$deadline" ]; do
    if "$@" >/dev/null 2>&1; then return 0; fi
    sleep 1
  done
  fail 'readiness deadline exceeded'
}
request() {
  expected=$1
  path=$2
  shift 2
  actual=$(curl --disable --silent --show-error --noproxy '*' --max-time 5 \
    --cacert "$work/tls.crt" --dump-header "$work/headers" \
    --output "$work/body" --write-out '%{http_code}' "$@" "$origin$path")
  [ "$actual" = "$expected" ] || fail "unexpected HTTP status (wanted $expected)"
}
ready() {
  code=$(curl --disable --silent --noproxy '*' --max-time 2 --cacert "$work/tls.crt" \
    --output /dev/null --write-out '%{http_code}' "$origin/readyz") || return 1
  [ "$code" = 200 ]
}
mark_phase setup
printf '%s\n' 'postgres://dans_runtime:dans-runtime@postgres/dans?sslmode=disable' >"$work/database-url"
printf '%s\n' 'dans_v1_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA' >"$work/powerdns-api-key"
redis_password=$(openssl rand -hex 32)
printf 'redis://dans:%s@redis:6379/0\n' "$redis_password" >"$work/redis-url"
printf '%s\n' 'user default off' \
  "user dans on >$redis_password ~dans:rl:* resetchannels -@all +eval +evalsha +hmget +hset +pexpire +time +ping" >"$work/redis-users.acl"
cat >"$work/openssl.cnf" <<'EOF'
[req]
distinguished_name = subject
x509_extensions = extensions
prompt = no
[subject]
CN = localhost
[extensions]
subjectAltName = DNS:localhost,IP:127.0.0.1
EOF
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -config "$work/openssl.cnf" \
  -keyout "$work/tls.key" -out "$work/tls.crt" >/dev/null 2>&1
# Only synthetic leaf files are readable; their host parent remains mode 0700.
chmod 444 "$work/database-url" "$work/powerdns-api-key" "$work/redis-url" "$work/redis-users.acl" "$work/tls.crt" "$work/tls.key"
docker build --build-arg VERSION=deployment-test --tag "$DANS_IMAGE" "$root"
image_built=1
docker network create --internal --label "com.docker.compose.project=$project" "$DANS_DATABASE_NETWORK" >/dev/null
database_network_created=1
docker network create --internal --label "com.docker.compose.project=$project" "$DANS_POWERDNS_NETWORK" >/dev/null
powerdns_network_created=1

mark_phase services
compose up --detach postgres powerdns
wait_for compose exec -T postgres pg_isready -h 127.0.0.1 -U dans_ddl -d dans
compose run --rm --no-deps -T \
  -e DANS_DATABASE_URL_FILE= \
  -e DANS_DATABASE_URL=postgres://dans_ddl:dans-ddl@postgres/dans?sslmode=disable dans db migrate
compose exec -T postgres psql -X -U dans_ddl -d dans -v ON_ERROR_STOP=1 \
  -v database_name=dans -v schema_name=public -v runtime_role=dans_runtime \
  <"$root/internal/database/privileges/runtime.sql" >/dev/null
compose run --rm --no-deps -T dans --output json bootstrap \
  --handle deployment-test --display-name 'Deployment test' --token-label deployment-test >"$work/bootstrap.json"
token=$(jq -er '.secret' "$work/bootstrap.json")
jq -n --arg token "$token" '{token:$token}' >"$work/login.json"
printf 'X-API-Key: %s\n' "$token" >"$work/token-header"
compose up --detach dans ingress redis
wait_for ready
if [ "${DANS_DEPLOY_TEST_INJECT_FAILURE:-}" = after-ready ]; then
  fail 'injected failure after readiness'
fi

mark_phase exercise
# Inspect actual bindings, including unexpected additional ports on ingress.
for service in dans postgres powerdns ingress redis; do
  container=$(compose ps --quiet "$service")
  docker inspect "$container" >"$work/container.json"
  case "$service" in
    dans | postgres | redis) jq -e '.[0].HostConfig.PortBindings | length == 0' "$work/container.json" >/dev/null ;;
    powerdns) jq -e '.[0].HostConfig.PortBindings | keys == ["53/tcp", "53/udp"] and all(.[][]; .HostIp == "127.0.0.1")' "$work/container.json" >/dev/null ;;
    ingress) jq -e '.[0].HostConfig.PortBindings | keys == ["8443/tcp"] and all(.[][]; .HostIp == "127.0.0.1")' "$work/container.json" >/dev/null ;;
  esac
done
dans_container=$(compose ps --quiet dans)
private_networks=$(docker inspect --format '{{range $name, $_ := .NetworkSettings.Networks}}{{$name}} {{end}}' "$dans_container")
for network in $private_networks; do
  [ "$(docker network inspect --format '{{.Internal}}' "$network")" = true ] || fail 'DANS has a public network'
done
powerdns_container=$(compose ps --quiet powerdns)
powerdns_ip=$(docker inspect --format "{{(index .NetworkSettings.Networks \"$DANS_POWERDNS_NETWORK\").IPAddress}}" "$powerdns_container")
compose exec -T ingress wget -S -T 2 -O /dev/null http://dans:8080/readyz \
  >"$work/ingress-probe" 2>&1 || fail 'ingress HTTP probe is unavailable'
probe_status=0
compose exec -T ingress wget -S -T 2 -O /dev/null "http://$powerdns_ip:8081/" \
  >"$work/upstream-probe" 2>&1 || probe_status=$?
if [ "$probe_status" -eq 0 ] || grep -Eq 'HTTP/[0-9.]+' "$work/upstream-probe"; then
  fail 'ingress can reach the private upstream API'
fi
compose exec -T ingress sh -c 'command -v nc' >/dev/null 2>&1 || fail 'ingress lacks nc for the Redis isolation probe'
if compose exec -T ingress nc -z -w 2 redis 6379 >/dev/null 2>&1; then
  fail 'ingress can reach the rate-limit Redis'
fi
redis_container=$(compose ps --quiet redis)
for network in $(docker inspect --format '{{range $name, $_ := .NetworkSettings.Networks}}{{$name}} {{end}}' "$redis_container"); do
  [ "$(docker network inspect --format '{{.Internal}}' "$network")" = true ] || fail 'Redis has a public network'
done

request 200 /console/
grep -Fq '<html' "$work/body" || fail 'embedded console is missing'
request 401 /api/v1/dans/me
request 403 /api/v1/dans/session -X POST -H 'Origin: https://external.example' \
  -H 'Content-Type: application/json' --data-binary "@$work/login.json"
! grep -iq '^set-cookie:' "$work/headers" || fail 'forged sign-in set a cookie'
request 201 /api/v1/dans/session -X POST -H "Origin: $origin" \
  -H 'Content-Type: application/json' --data-binary "@$work/login.json" --cookie-jar "$work/cookies"
cookie=$(sed -n 's/^[Ss]et-[Cc]ookie: //p' "$work/headers" | tr -d '\r')
case "$cookie" in __Host-dans_session=session_v1_*) ;; *) fail 'wrong session cookie' ;; esac
for attribute in 'Path=/' 'HttpOnly' 'Secure' 'SameSite=Strict'; do
  printf '%s\n' "$cookie" | grep -Fq "$attribute" || fail 'missing protected cookie attribute'
done
if printf '%s\n' "$cookie" | grep -iq 'Domain='; then fail 'session cookie is not host-scoped'; fi
cp "$work/cookies" "$work/replay-cookies"
request 200 /api/v1/dans/me --cookie "$work/cookies"
grep -iq '^Cache-Control: no-store' "$work/headers" || fail 'authenticated response can be cached'

request 201 /api/v1/servers/localhost/zones -X POST --cookie "$work/cookies" \
  -H "Origin: $origin" -H 'Content-Type: application/json' \
  --data '{"name":"deployment.test.","kind":"Native","nameservers":["ns1.example.test.","ns2.example.test."]}'
rrset='{"rrsets":[{"name":"host.deployment.test.","type":"A","ttl":60,"changetype":"REPLACE","records":[{"content":"192.0.2.80","disabled":false}]}]}'
request 204 /api/v1/servers/localhost/zones/deployment.test. -X PATCH --cookie "$work/cookies" \
  -H "Origin: $origin" -H 'Content-Type: application/json' --data "$rrset"
answer=$(dig @127.0.0.1 -p "$DANS_DEPLOY_DNS_PORT" host.deployment.test. A +short +time=2 +tries=1)
[ "$answer" = 192.0.2.80 ] || fail 'authorized TLS write did not reach authoritative DNS'
request 403 /api/v1/servers/localhost/zones/deployment.test. -X PATCH --cookie "$work/cookies" \
  -H 'Origin: https://external.example' -H 'Content-Type: application/json' \
  --data "$(printf '%s' "$rrset" | sed 's/192.0.2.80/192.0.2.81/')"
answer=$(dig @127.0.0.1 -p "$DANS_DEPLOY_DNS_PORT" host.deployment.test. A +short +time=2 +tries=1)
[ "$answer" = 192.0.2.80 ] || fail 'forged write changed authoritative DNS'
request 403 /api/v1/dans/session -X DELETE --cookie "$work/cookies" -H 'Sec-Fetch-Site: cross-site'
request 200 /api/v1/dans/me --cookie "$work/cookies"
request 204 /api/v1/dans/session -X DELETE --cookie "$work/cookies" \
  --cookie-jar "$work/cookies" -H "Origin: $origin"
request 401 /api/v1/dans/me --cookie "$work/replay-cookies"
request 200 /api/v1/dans/me --header "@$work/token-header"

# Shared rate limiting is active through the private, ACL-protected Redis.
# The test policy refills one request token every 1000s, well beyond the
# capacity-plus-one probe even when every curl uses its full 5s timeout.
probe_requests=$(jq -er '.defaults.requests.capacity + 1' "$root/integration/ratelimit/deployment.json")
throttled=0
attempt=0
while [ "$attempt" -lt "$probe_requests" ] && [ "$throttled" -eq 0 ]; do
  attempt=$(( attempt + 1 ))
  code=$(curl --disable --silent --noproxy '*' --max-time 5 --cacert "$work/tls.crt" \
    --dump-header "$work/headers" --output "$work/body" --write-out '%{http_code}' \
    --header "@$work/token-header" "$origin/api/v1/dans/me")
  case "$code" in
    200) ;;
    429) throttled=1 ;;
    *) fail "unexpected HTTP status during rate-limit burst ($code)" ;;
  esac
done
[ "$throttled" -eq 1 ] || fail 'rate limiting never throttled the burst'
grep -iq '^Retry-After: [1-9]' "$work/headers" || fail 'throttle lacks Retry-After'
grep -iq '^X-DANS-RateLimit-Bucket: ' "$work/headers" || fail 'throttle lacks the bucket header'
if compose logs --no-color dans | grep -Fq 'rate_limit.fail_open'; then
  fail 'DANS could not use the ACL-protected Redis'
fi

compose logs --no-color >"$work/runtime.log"
session=${cookie%%;*}
session=${session#*=}
for credential in "$token" "$session" "$redis_password" dans_v1_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA; do
  if grep -Fq "$credential" "$work/runtime.log"; then fail 'credential appeared in runtime logs'; fi
done
printf '%s\n' 'deployment test: ok'
completed=1
