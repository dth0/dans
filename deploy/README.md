# Deployment examples

These examples preserve the supported production boundary:

```text
client --TLS--> trusted ingress --> private DANS --> PostgreSQL primary
                                             \--> private PowerDNS API
```

PostgreSQL and PowerDNS are external dependencies. The examples do not publish the DANS listener or PowerDNS API, and only DANS receives the PowerDNS key. Authoritative DNS on port 53 remains independent of DANS.

## Docker or Podman Compose

The Compose example expects existing `database-private` and `powerdns-control` networks. Attach the external PostgreSQL primary to the first and the PowerDNS API listener to the second. Do not publish the PowerDNS API port on the host. Its configured `api-allow-from` must also restrict clients to the DANS network address range.

Create the networks once, then run the example with absolute paths to secret files and a private PowerDNS URL:

```sh
docker network create --internal database-private
docker network create --internal powerdns-control

export DANS_IMAGE=ghcr.io/ncode/dans:RELEASE
export DANS_POWERDNS_URL=http://powerdns:8081
export DANS_DATABASE_SECRET_FILE=/secure/dans/database-url
export DANS_POWERDNS_SECRET_FILE=/secure/dans/powerdns-api-key
export DANS_TLS_CERT_FILE=/secure/dans/tls.crt
export DANS_TLS_KEY_FILE=/secure/dans/tls.key
docker compose --file deploy/docker/compose.yaml up -d
```

Use `podman network create --internal ...` and `podman compose --file deploy/docker/compose.yaml up -d` for Podman. Ensure the host secret files are readable by container UID 65532 without making them generally readable. The only published socket is the ingress's TLS port 443; DANS itself joins only private networks.

The stock Caddy executable carries the `NET_BIND_SERVICE` file capability. The ingress drops all other capabilities and retains this one so the executable can start, even though its container listener uses port 8443. DANS retains no Linux capabilities.

Ingress also joins an external-facing bridge so Docker can publish its TLS socket. DANS joins only the internal ingress network and the two private dependency networks.

## Kubernetes

The manifest assumes:

- an ingress class named `trusted`, with its controller namespace labeled `networking.dans.io/trusted-ingress=true` and controller pods labeled `app.kubernetes.io/component=controller`;
- an external PostgreSQL primary in a namespace labeled `networking.dans.io/postgresql=true`, with pods labeled `app.kubernetes.io/name=postgresql`;
- PowerDNS in namespace `powerdns`, labeled at the namespace level with `networking.dans.io/powerdns=true` and at the pod level with `app.kubernetes.io/name=powerdns`;
- a PowerDNS API Service named `powerdns-api` on port 8081; and
- a TLS Secret named `dans-tls` in namespace `dans`.

Replace the image tag, host, service names, labels, and ports for the deployment. If PostgreSQL is a managed service outside the cluster, replace its namespace/pod egress selector with the provider's stable `ipBlock`; do not open unrestricted egress.

Create secret objects from files rather than placing plaintext in manifests:

```sh
kubectl create namespace dans --dry-run=client -o yaml | kubectl apply -f -
kubectl --namespace dans create secret generic dans-runtime \
  --from-file=database-url=/secure/dans/database-url \
  --from-file=powerdns-api-key=/secure/dans/powerdns-api-key
kubectl --namespace dans create secret tls dans-tls \
  --cert=/secure/dans/tls.crt --key=/secure/dans/tls.key
kubectl apply --filename deploy/kubernetes/dans.yaml
```

The pod runs as UID/GID 65532 with a read-only filesystem and no Linux capabilities. NetworkPolicy admits API traffic only from the trusted ingress and permits DANS egress only to DNS, PostgreSQL, and PowerDNS. The PowerDNS-side policy allows public authoritative DNS on port 53 but admits its HTTP API only from DANS. Adapt the selectors to the actual ingress and dependency labels before applying the policy.

## Runtime verification

Required CI runs `scripts/deploy-runtime_test.sh postgres:16.14` through the privacy-safe integration entry point. The test layers disposable dependencies and loopback test ports over the Docker example, keeping its Caddyfile, service security settings, and file-secret configuration. It validates TLS with an explicitly trusted synthetic certificate, readiness, embedded console delivery, secure cookie authentication, a DNS write, cross-origin denial, logout, and private listener isolation. An injected failure also verifies cleanup.

To run the same check locally, install Docker Compose 2.24.4 or newer, curl, dig, jq, and OpenSSL:

```sh
umask 077
evidence=$(mktemp -d)
DANS_QA_LOG_DIR="$evidence/raw" DANS_QA_SUMMARY_DIR="$evidence/summary" \
  scripts/integration-ci.sh scripts/deploy-runtime_test.sh postgres:16.14
```

Raw evidence stays in the private directory; only a fixed phase summary is suitable for publication. The test removes its own containers, networks, volumes, image tag, and generated secret files. Its synthetic secret files sit beneath a mode-0700 host directory and are readable inside their individual container mounts; use appropriate restricted ownership or ACLs when provisioning production secrets. The runtime gate covers Docker Compose and API session transport. Kubernetes configuration is rendered by `scripts/deploy-smoke.sh`; cluster NetworkPolicy enforcement, Podman behavior, and browser rendering are separate verification concerns.
