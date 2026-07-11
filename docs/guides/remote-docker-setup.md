# Remote Docker Setup

This guide configures Paid to run agent containers on one remote Docker host over TCP with mutual TLS.

The most practical self-hosted case is a laptop or devcontainer running the Paid control plane while a QNAP NAS runs the agent containers over Tailscale. That setup moves container CPU and memory pressure off the development machine without changing Paid's runtime model.

## Overview

Paid keeps the existing named-volume plus in-container clone workflow. The only runtime difference is that Docker API calls go to a remote daemon instead of `/var/run/docker.sock`.

Required pieces:

- Remote Docker Engine listening on TCP with client-certificate auth
- The `paid_agent` and `paid_internal` Docker networks on the remote host
- The `paid-agent:latest` image available on the remote host
- A routable proxy address for agent containers via `PAID_PROXY_EXTERNAL_URL`
- The Paid app configured with `CONTAINER_BACKEND=remote` and remote TLS cert paths

For the QNAP/NAS scenario, Tailscale is a good fit because it gives both machines stable private IPs without exposing the Docker API to the public internet.

## QNAP + Tailscale Topology

```text
Laptop / devcontainer                    QNAP NAS (Tailscale)
┌─────────────────────┐                 ┌──────────────────────┐
│ Paid Rails app      │                 │ Container Station    │
│ Temporal workers    │── Tailscale ──▶│ dockerd :2376 (mTLS) │
│ GoodJob             │   TCP 2376     │                      │
│                     │◀── Tailscale ──│ Agent containers     │
│ :3000 (proxy)       │   HTTP :3000   │ clone, build, run    │
└─────────────────────┘                 └──────────────────────┘
```

Two directions matter:

- Paid -> NAS on TCP `2376`: Docker API calls to create, start, exec, inspect, and stop containers
- NAS containers -> Paid on HTTP `:3000`: secrets-proxy traffic for LLM access and proxy-issued credentials

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

Lock TCP `2376` down to Tailscale-only access. Do not expose it on the public LAN or internet.

Create the two Docker networks Paid expects:

```bash
docker network create paid_agent
docker network create paid_internal
```

`paid_agent` is the restricted proxy-mode network. `paid_internal` is the unrestricted network used for direct-outbound and subscription-auth cases.

## 2. Install Tailscale on Both Sides

Install Tailscale on the QNAP from the QNAP App Center. Install Tailscale on the laptop or the host that runs the devcontainer.

Verify both machines can reach each other over Tailscale:

```bash
ping <qnap-tailscale-ip>
ping <laptop-tailscale-ip>
```

Tailscale IPs are stable enough to use directly in the remote Docker and proxy environment variables.

## 3. Generate and Distribute TLS Certificates

Paid ships a helper task for the CA and client bundle:

```bash
bundle exec rake remote_docker:generate_certs[tmp/remote-docker-certs,paid-qnap-client]
```

This writes:

- `ca.pem`
- `ca-key.pem`
- `client-cert.pem`
- `client-key.pem`

Important detail: the task does not generate the server certificate pair for the NAS daemon. You still need to create `server-cert.pem` and `server-key.pem` separately, signed by the generated `ca-key.pem`, or use another server certificate that the generated `ca.pem` will trust.

Distribution model:

- Keep `client-cert.pem`, `client-key.pem`, and `ca.pem` on the Paid control-plane host
- Install `ca.pem`, `server-cert.pem`, and `server-key.pem` on the QNAP Docker daemon
- Treat `ca-key.pem` as highly sensitive; store it securely offline after signing, or delete it if you do not need to sign additional server certificates

At a minimum, the NAS daemon must trust `ca.pem`, and the Paid host must present the client cert pair referenced by `REMOTE_DOCKER_CERT` and `REMOTE_DOCKER_KEY`.

## 4. Make the Agent Image Available on the NAS

The remote daemon must have the `paid-agent:latest` image available before Paid can start runs there.

Options:

- Save and transfer manually:

```bash
docker save paid-agent:latest | gzip > /tmp/paid-agent.tgz
scp /tmp/paid-agent.tgz <qnap-user>@<qnap-tailscale-ip>:/tmp/
ssh <qnap-user>@<qnap-tailscale-ip> 'gunzip -c /tmp/paid-agent.tgz | docker load'
```

- Push to a registry the NAS can pull from, such as Docker Hub, GHCR, or a private registry
- Set up a cron job or deploy hook on the NAS to keep `paid-agent:latest` current

If the image is missing, remote provisioning will fail even if the TLS connection itself is healthy.

## 5. Configure Paid

Set these environment variables on the Paid control plane:

```bash
CONTAINER_BACKEND=remote
REMOTE_DOCKER_HOST=<qnap-tailscale-ip>:2376
REMOTE_DOCKER_IDENTIFIER=qnap-nas
REMOTE_DOCKER_CERT=/path/to/client-cert.pem
REMOTE_DOCKER_KEY=/path/to/client-key.pem
REMOTE_DOCKER_CA=/path/to/ca.pem
PAID_PROXY_EXTERNAL_URL=http://<laptop-tailscale-ip>:3000
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

## 6. Verify Connectivity

First, test raw Docker API connectivity:

```bash
bundle exec rake remote_docker:test_connection
```

Expected output is an `OK` ping from the configured remote backend.

Then verify an actual run:

1. Start Paid with the remote env vars.
2. Queue a test agent run.
3. Confirm the created container appears on the QNAP, not on the local Docker daemon.
4. Confirm the agent can still reach the secrets proxy through `PAID_PROXY_EXTERNAL_URL`.

Operational checks worth doing after the first successful run:

- Metrics collection works against the remote daemon because Paid resolves stats through `Containers.backend_for(agent_run.container_host)`
- Orphan cleanup scans both local and remote backends because cleanup iterates `Containers.all_backends`
- Both `paid_agent` and `paid_internal` are present on the NAS and the run lands on the expected network

## 7. Known Constraints

- No host bind mounts. The remote backend reports `supports_host_paths? = false`, so host credential-file mounting does not work. For subscription auth, use managed credentials stored as `RunnerCredential` records or switch to API-key auth mode.
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
