# Remote Docker Setup

This guide configures Paid to run agent containers on a remote Docker host over TCP with mutual TLS.

The most practical self-hosted case is a laptop or devcontainer running the Paid control plane while a QNAP NAS runs the agent containers over Tailscale. That setup moves container CPU and memory pressure off the development machine without changing Paid's runtime model.

Paid supports two remote Docker operating modes:

- `CONTAINER_BACKEND=remote`: all new agent runs use one configured remote Docker daemon.
- `CONTAINER_BACKEND=multi`: local Docker and one or more remote Docker daemons are registered together through `CONTAINER_BACKENDS_CONFIG`.

Use `remote` when the remote host should replace local Docker. Use `multi` when the remote host should add capacity while local Docker stays available.

## Overview

Paid keeps the existing named-volume plus in-container clone workflow. The only runtime difference is that Docker API calls go to a remote daemon instead of `/var/run/docker.sock`.

Required pieces:

- Remote Docker Engine listening on TCP with client-certificate auth
- The `paid_agent` and `paid_internal` Docker networks on the remote host
- The `paid-agent:latest` image available on the remote host
- A routable proxy address for agent containers via `PAID_PROXY_EXTERNAL_URL`
- The Paid app configured with either `CONTAINER_BACKEND=remote` or `CONTAINER_BACKEND=multi`

For the QNAP/NAS scenario, Tailscale is a good fit because it gives both machines stable private IPs without exposing the Docker API to the public internet.

## QNAP + Tailscale Topology

```text
Laptop / devcontainer                    QNAP NAS (Tailscale)
+---------------------+                 +----------------------+
| Paid Rails app      |                 | Container Station    |
| Temporal workers    |-- Tailscale --->| dockerd :2376 (mTLS) |
| GoodJob             |   TCP 2376      |                      |
|                     |<-- Tailscale ---| Agent containers     |
| :3000 (proxy)       |   HTTP :3000    | clone, build, run    |
+---------------------+                 +----------------------+
```

Two directions matter:

- Paid -> NAS on TCP `2376`: Docker API calls to create, start, exec, inspect, and stop containers
- NAS containers -> Paid on HTTP `:3000`: secrets-proxy traffic for LLM access and proxy-issued credentials

Walkthrough topology:

- Paid runs inside a devcontainer on a laptop or workstation
- The Paid host has a stable Tailscale IP, shown below as `<paid-host-tailscale-ip>`
- The QNAP has a stable Tailscale IP, shown below as `<qnap-tailscale-ip>`
- The QNAP may also have a LAN IP, shown below as `<qnap-lan-ip>`
- The QNAP may use a nonstandard SSH port, shown below as `<qnap-ssh-port>`

Before troubleshooting Docker connectivity, confirm the configured QNAP SSH port in Control Panel > Network & File Services > Telnet / SSH. Then verify SSH reachability on LAN and Tailscale:

```bash
nc -vz <qnap-lan-ip> <qnap-ssh-port>
nc -vz <qnap-tailscale-ip> <qnap-ssh-port>
ssh -p <qnap-ssh-port> <qnap-user>@<qnap-tailscale-ip>
```

## Host vs. Devcontainer Commands

Run host-network and Docker CLI transfer commands on the laptop or machine that can reach both Tailscale and the Docker socket:

- `ssh`, `scp`, `nc`, and Tailscale CLI checks
- `docker save paid-agent:latest | gzip > /tmp/paid-agent.tgz`
- `docker load` against `DOCKER_HOST=tcp://<qnap-tailscale-ip>:2376`

Run Paid/Rails commands inside the devcontainer:

- `bundle exec rake remote_docker:test_connection`
- `bundle exec rake remote_docker:generate_certs[...]`
- `bin/rails runner ...`
- Environment verification for `CONTAINER_BACKEND`, `REMOTE_DOCKER_*`, and `PAID_PROXY_EXTERNAL_URL`

## 1. Configure the QNAP Docker Host

Enable Container Station on the QNAP so the NAS exposes a Docker-compatible daemon. Then configure the daemon to listen on TCP with TLS verification enabled.

Docker's TLS guidance is here:

- <https://docs.docker.com/engine/security/https/>

Typical daemon flags:

```bash
dockerd \
  --host=unix:///var/run/docker.sock \
  --host=tcp://0.0.0.0:2376 \
  --tlsverify \
  --tlscacert=/etc/docker/tls/ca.pem \
  --tlscert=/etc/docker/tls/server-cert.pem \
  --tlskey=/etc/docker/tls/server-key.pem
```

If your QNAP uses a JSON daemon config instead of CLI flags, the equivalent fields are:

```json
{
  "hosts": ["unix:///var/run/docker.sock", "tcp://0.0.0.0:2376"],
  "tlsverify": true,
  "tlscacert": "/etc/docker/tls/ca.pem",
  "tlscert": "/etc/docker/tls/server-cert.pem",
  "tlskey": "/etc/docker/tls/server-key.pem"
}
```

In the verified QNAP setup, Container Station already had Docker listening on `tcp://0.0.0.0:2376` with mTLS enabled:

```text
--tlscacert=/etc/docker/tls/ca.pem
--tlscert=/etc/docker/tls/server.pem
--tlskey=/etc/docker/tls/server-key.pem
```

The QNAP TLS directory included:

```text
/etc/docker/tls/ca.pem
/etc/docker/tls/ca-key.pem
/etc/docker/tls/server.pem
/etc/docker/tls/server-cert.pem
/etc/docker/tls/server-key.pem
/etc/docker/tls/cert.pem
/etc/docker/tls/key.pem
```

The existing `/etc/docker/tls/cert.pem` client certificate had `TLS Web Client Authentication`, and `/etc/docker/tls/key.pem` matched it, so we reused the QNAP-provided client cert instead of generating a new client bundle.

Lock TCP `2376` down to Tailscale-only access. Do not expose it on the public LAN or internet.

Create the two Docker networks Paid expects:

```bash
docker network create \
  --driver bridge \
  --subnet 172.28.0.0/16 \
  paid_agent

docker network create \
  --driver bridge \
  --subnet 172.29.8.0/22 \
  paid_internal
```

`paid_agent` is the restricted proxy-mode network. `paid_internal` is the unrestricted network used for direct-outbound and subscription-auth cases.

Do not create `paid_agent` as a Docker `--internal` network on remote hosts today. Remote proxy-mode containers must call `PAID_PROXY_EXTERNAL_URL` on the Paid control plane, and Docker-internal bridge networks block that callback. Paid's in-container firewall rules still provide the egress restriction layer. See issue `#3545`.

## 2. Install Tailscale on Both Sides

Install Tailscale on the QNAP from the QNAP App Center. Install Tailscale on the laptop or the host that runs the devcontainer.

Verify both machines can reach each other over Tailscale:

```bash
ping <qnap-tailscale-ip>
ping <laptop-tailscale-ip>
```

Tailscale IPs are stable enough to use directly in the remote Docker and proxy environment variables.

### QNAP QuFirewall

If Tailscale ping works but the SSH port or Docker TCP `2376` times out, add a QuFirewall allow rule:

- Permission: Allow
- Interface: `tailscale0` if shown, otherwise All
- Source: the Paid host Tailscale IP as `/32`, for example `<paid-host-tailscale-ip>/32`
- Protocol: TCP
- Ports: `2376,<qnap-ssh-port>`

QuFirewall created an effective rule like:

```text
ACCEPT tcp -- <paid-host-tailscale-ip> 0.0.0.0/0 multiport dports 2376,<qnap-ssh-port>
```

Then verify both ports over Tailscale:

```bash
nc -vz -G 5 <qnap-tailscale-ip> <qnap-ssh-port>
nc -vz -G 5 <qnap-tailscale-ip> 2376
```

## 3. Download or Generate TLS Certificates

For QNAP Container Station, prefer the built-in certificate download first:

1. Open Container Station in the QNAP web UI.
2. Open Preferences or Settings.
3. Find the Docker Certificate / Docker API certificate section.
4. Download and unzip the certificate bundle.

The bundle should include:

```text
ca.pem
cert.pem
key.pem
```

Copy those files to the Paid workspace:

```text
tmp/remote-docker-certs/ca.pem
tmp/remote-docker-certs/cert.pem
tmp/remote-docker-certs/key.pem
```

Then `DOCKER_CERT_PATH=tmp/remote-docker-certs` works with Docker CLI, and Paid can point `REMOTE_DOCKER_CERT` at `cert.pem` and `REMOTE_DOCKER_KEY` at `key.pem`.

If the QNAP UI certificate bundle is unavailable, generate your own CA and client bundle.

Paid ships a helper task for the CA and client bundle:

```bash
bundle exec rake remote_docker:generate_certs[tmp/remote-docker-certs,paid-qnap-client]
```

This writes:

- `ca.pem`
- `ca-key.pem`
- `client-cert.pem`
- `client-key.pem`

Important detail: the task does not generate the server certificate pair for the NAS daemon. You still need to create `server-cert.pem` and `server-key.pem` separately, signed by the generated `ca-key.pem`, or use another server certificate that the generated `ca.pem` will trust. Make sure `server-cert.pem` includes a `subjectAltName` for the exact host clients use in `REMOTE_DOCKER_HOST`. If `REMOTE_DOCKER_HOST` uses the QNAP Tailscale IP, that IP must appear in the certificate SAN list or Docker TLS hostname verification will fail even when the CA and client certs are otherwise correct.

Distribution model:

- Keep `client-cert.pem`, `client-key.pem`, and `ca.pem` on the Paid control-plane host
- Install `ca.pem`, `server-cert.pem`, and `server-key.pem` on the QNAP Docker daemon
- Treat `ca-key.pem` as highly sensitive; store it securely offline after signing, or delete it if you do not need to sign additional server certificates

At a minimum, the NAS daemon must trust `ca.pem`, and the Paid host must present the client cert pair referenced by `REMOTE_DOCKER_CERT` and `REMOTE_DOCKER_KEY`.

If the QNAP already has a working client certificate outside the web UI, copy it into the Paid workspace instead:

```text
tmp/remote-docker-certs/ca.pem
tmp/remote-docker-certs/cert.pem
tmp/remote-docker-certs/key.pem
```

For compatibility with older examples, copies named `client-cert.pem` and `client-key.pem` are fine too:

```text
tmp/remote-docker-certs/client-cert.pem
tmp/remote-docker-certs/client-key.pem
```

Docker CLI requires `ca.pem`, `cert.pem`, and `key.pem` under `DOCKER_CERT_PATH`. Paid's env vars can point at either naming convention.

QNAP `scp` may fail because modern `scp` uses SFTP by default and some QNAP SSH setups do not provide the expected SFTP subsystem. Use legacy SCP mode or stream over SSH:

```bash
scp -O -P <qnap-ssh-port> <qnap-user>@<qnap-tailscale-ip>:/etc/docker/tls/cert.pem tmp/remote-docker-certs/client-cert.pem
ssh -p <qnap-ssh-port> <qnap-user>@<qnap-tailscale-ip> 'cat /etc/docker/tls/key.pem' > tmp/remote-docker-certs/client-key.pem
ssh -p <qnap-ssh-port> <qnap-user>@<qnap-tailscale-ip> 'cat /etc/docker/tls/ca.pem' > tmp/remote-docker-certs/ca.pem
cp tmp/remote-docker-certs/client-cert.pem tmp/remote-docker-certs/cert.pem
cp tmp/remote-docker-certs/client-key.pem tmp/remote-docker-certs/key.pem
```

## 4. Make the Agent Image Available on the NAS

The remote daemon must have the `paid-agent:latest` image available before Paid can start runs there.

The supported local build path is:

```bash
./scripts/build-agent-image.sh
```

Do not use `docker compose --profile setup build agent-image` for this flow. The agent Dockerfile now requires build arguments extracted from `Gemfile.lock` and `agent-harness`; `scripts/build-agent-image.sh` is the maintained path that computes and passes those values.

QNAP-specific caveats:

- If the QNAP is `x86_64`, the image loaded there must be `linux/amd64`. On Apple Silicon or other ARM development hosts, build an amd64 image, for example with `DOCKER_DEFAULT_PLATFORM=linux/amd64 IMAGE_TAG=qnap-amd64 ./scripts/build-agent-image.sh`, then tag it as `paid-agent:latest` on the QNAP.
- Native image builds on QNAP Container Station may fail while extracting Ruby tarballs with `tar: ... Cannot change mode ... Bad address`; see issue `#3544`. Building elsewhere and loading the image onto QNAP is the safer path for now.
- The Oh My Pi Bun installer can drift from the `agent-harness` Bun pin; see issue `#3542`. If the build fails at the Oh My Pi Bun version check, fix the pin/contract before treating QNAP as broken.

Options for getting the image onto the NAS:

- Save and transfer manually:

```bash
docker save paid-agent:latest | gzip > /tmp/paid-agent.tgz
gunzip -c /tmp/paid-agent.tgz | \
  DOCKER_HOST=tcp://<qnap-tailscale-ip>:2376 \
  DOCKER_TLS_VERIFY=1 \
  DOCKER_CERT_PATH="$PWD/tmp/remote-docker-certs" \
  docker load
```

- Push to a registry the NAS can pull from, such as Docker Hub, GHCR, or a private registry
- Set up a cron job or deploy hook on the NAS to keep `paid-agent:latest` current

If the image is missing, remote provisioning will fail even if the TLS connection itself is healthy.

For the verified walkthrough, the image was built inside the Paid devcontainer as `linux/amd64`, saved from the laptop Docker context, loaded into the QNAP Docker daemon over mTLS, tagged on the QNAP as `paid-agent:latest`, and smoke-tested there.

## 5. Configure Paid

### Single Remote Backend

Set these environment variables on the Paid control plane:

```bash
CONTAINER_BACKEND=remote
REMOTE_DOCKER_HOST=<qnap-tailscale-ip>:2376
REMOTE_DOCKER_IDENTIFIER=qnap-nas
REMOTE_DOCKER_CERT=/workspaces/paid/tmp/remote-docker-certs/cert.pem
REMOTE_DOCKER_KEY=/workspaces/paid/tmp/remote-docker-certs/key.pem
REMOTE_DOCKER_CA=/workspaces/paid/tmp/remote-docker-certs/ca.pem
PAID_PROXY_EXTERNAL_URL=http://<paid-host-tailscale-ip>:3000
```

What each variable does:

- `CONTAINER_BACKEND=remote`: selects `Containers::Backends::RemoteDocker`
- `REMOTE_DOCKER_HOST`: the NAS Docker API endpoint; `host:port` and `tcp://host:port` both work
- `REMOTE_DOCKER_IDENTIFIER`: the backend identifier Paid persists into `agent_runs.container_host`
- `REMOTE_DOCKER_CERT`: client certificate for mTLS auth to the NAS daemon
- `REMOTE_DOCKER_KEY`: private key for the client certificate
- `REMOTE_DOCKER_CA`: CA bundle used to verify the NAS daemon certificate
- `PAID_PROXY_EXTERNAL_URL`: the externally routable URL remote containers use to reach the secrets proxy

`PAID_PROXY_EXTERNAL_URL` is mandatory for remote backends. Remote agent containers cannot resolve Docker-local names like `paid-proxy`, so Paid must hand them an address reachable from the NAS over Tailscale.

Use the laptop's Tailscale IP in `PAID_PROXY_EXTERNAL_URL` so containers running on the NAS can call back into the Paid app.

Replace `<qnap-tailscale-ip>` with the remote Docker host's Tailscale IP and `<paid-host-tailscale-ip>` with the Paid control-plane host's Tailscale IP.

### Local Plus QNAP Backend

Use `CONTAINER_BACKEND=multi` when local Docker should keep handling runs by default and QNAP should be available as another host:

```yaml
CONTAINER_BACKEND=multi
CONTAINER_BACKENDS_CONFIG: |
  default_host: local
  fallback: disabled
  hosts:
    local:
      type: local
      concurrency:
        max_concurrent_runs: 2
    qnap-nas:
      type: remote
      host: tcp://<qnap-tailscale-ip>:2376
      proxy_external_url: http://<paid-host-tailscale-ip>:3000
      tls:
        ca_file: /workspaces/paid/tmp/remote-docker-certs/ca.pem
        client_cert: /workspaces/paid/tmp/remote-docker-certs/cert.pem
        client_key: /workspaces/paid/tmp/remote-docker-certs/key.pem
      concurrency:
        max_concurrent_runs: 2
```

`default_host: local` keeps ordinary placement local unless code or scheduling policy selects another host. The Docker Hosts UI records are useful for setup and readiness workflows, but runtime multi-host scheduling still requires `CONTAINER_BACKEND=multi` and `CONTAINER_BACKENDS_CONFIG`.

## 6. Verify Connectivity

For `CONTAINER_BACKEND=remote`, test raw Docker API connectivity:

```bash
bundle exec rake remote_docker:test_connection
```

Expected output is an `OK` ping from the configured remote backend.

Verified walkthrough output:

```text
Remote backend qnap-nas responded with "OK"
```

You can also test Docker CLI connectivity from the host:

```bash
DOCKER_HOST=tcp://<qnap-tailscale-ip>:2376 \
DOCKER_TLS_VERIFY=1 \
DOCKER_CERT_PATH="$PWD/tmp/remote-docker-certs" \
docker version
```

Then verify an actual run:

1. Start Paid with the remote env vars.
2. Queue a test agent run.
3. Confirm the created container appears on the QNAP, not on the local Docker daemon.
4. Confirm the agent can still reach the secrets proxy through `PAID_PROXY_EXTERNAL_URL`.

The walkthrough smoke test created a QNAP container from `paid-agent:latest`, then exec'd:

```bash
curl -I --max-time 10 http://<paid-host-tailscale-ip>:3000
```

The request returned `HTTP/1.1 302 Found` with exit status `0`, and container cleanup succeeded.

Operational checks worth doing after the first successful run:

- Metrics collection works against the remote daemon because Paid resolves stats through `Containers.backend_for(agent_run.container_host)`
- Orphan cleanup scans both local and remote backends because cleanup iterates `Containers.all_backends`
- Both `paid_agent` and `paid_internal` are present on the NAS and the run lands on the expected network

## 7. Known Constraints

- No host bind mounts. The remote backend reports `supports_host_paths? = false`, so host credential-file mounting does not work. RDR-041's subscription auth host eligibility contract is enforced before provisioning, so unsupported subscription runs are rejected with a named reason rather than failing mid-run. Do not copy local subscription credential directories (`.claude`, `.codex`, etc.) to the remote Docker host — that path is not supported and creates credential sprawl that Paid cannot refresh. Instead, use managed `RunnerCredential` flows where supported:
  - Claude: managed credentials stored as `RunnerCredential` records (Claude OAuth) are fetched from the database and written into the container, so subscription auth works on remote Docker **without any bind mount**. This is the default subscription-auth path when a valid managed Claude credential exists. If only a host `.credentials.json` is present, remote provisioning is rejected with `requires_host_bind_mount`; add a managed Claude credential in the Runners UI to unlock remote placement.
  - Codex: still depends on a Docker-host `auth.json` bind mount, which the remote backend cannot provide. Remote provisioning is rejected with `requires_host_bind_mount`; use API-key auth mode for Codex on remote Docker in the meantime. Remote-safe managed Codex subscription auth remains tracked in follow-up issue `#2962`.
  - Gemini and Copilot: still need a local config copy (`oauth_creds.json` / `config.json`) readable on the Paid control plane, so subscription auth is rejected on remote Docker with `requires_host_bind_mount`. Use a host-path-capable backend for these runners. Remote-safe managed Gemini/Copilot subscription auth remains tracked in follow-up issue `#2964`.
  - API-key/proxy auth mode is eligible on remote Docker as long as `PAID_PROXY_EXTERNAL_URL` is reachable from the remote containers. If the proxy is unreachable, runs are rejected with `remote_proxy_unreachable`.
- Named rejection reasons surfaced by the scheduler/readiness layer include `requires_host_bind_mount`, `managed_auth_missing`, `provider_materializer_missing`, `credential_expired`, `credential_refresh_failed`, and `remote_proxy_unreachable`. These are safe to display in the operations UI and never contain secret material.
- Auto-capacity is conservative. Remote Docker is classified as shared infrastructure for capacity decisions, so use manual concurrency mode if you want predictable scheduling behavior.
- Recommended setting for predictability:

```text
run_concurrency_mode=manual
```

- Clone latency is higher. Fresh git clones happen on the NAS over the Tailscale path; expect roughly 30-60 seconds for larger repositories.
- Proxy round-trip adds network latency. Every proxied LLM call travels from the NAS container to the Paid app over Tailscale. On the same LAN this is usually single-digit milliseconds; across wider networks expect something more like 20-100 milliseconds.

## 8. Security Checklist

Confirm all of these before enabling production traffic:

- Docker API only accepts mTLS-authenticated clients
- TCP `2376` is reachable only through Tailscale or another private tunnel
- `PAID_PROXY_EXTERNAL_URL` points to an address the NAS can reach
- The NAS daemon trusts `ca.pem` and uses the matching `server-cert.pem` and `server-key.pem`
- The Paid control plane keeps `client-key.pem` and `ca-key.pem` out of source control and out of world-readable locations
- The remote host has the `paid-agent:latest` image available, or can pull it reliably

## Related Docs

- [Agent system overview](../AGENT_SYSTEM.md)
- [Remote container execution RDR](../rdrs/RDR-019-remote-container-execution.md)
- [Docker Engine TLS setup](https://docs.docker.com/engine/security/https/)
