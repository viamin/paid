# Remote Docker Setup

This guide configures Paid to run agent containers on one remote Docker host over TCP with mutual TLS.

## Overview

Paid keeps the existing named-volume plus in-container clone workflow. The only runtime difference is that Docker API calls go to a remote daemon instead of `/var/run/docker.sock`.

Required pieces:

- Remote Docker Engine listening on TCP with client-certificate auth
- A routable proxy address for agent containers via `PAID_PROXY_EXTERNAL_URL`
- The Paid app configured with `CONTAINER_BACKEND=remote` and remote TLS cert paths

## 1. Configure the Remote Docker Host

Enable the Docker API on the worker host with TLS verification. Docker’s TLS guidance is here:

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

Lock TCP/2376 down to the Paid control plane network only. Do not expose it publicly without network controls.

## 2. Generate Client TLS Material

Paid ships a helper task:

```bash
bundle exec rake remote_docker:generate_certs[tmp/remote-docker-certs,paid-worker-client]
```

This writes:

- `ca.pem`
- `ca-key.pem`
- `client-cert.pem`
- `client-key.pem`

For production, treat `ca-key.pem` as sensitive and store it outside the app host once you have signed the needed certificates.

## 3. Provide a Proxy Route

Remote agent containers cannot resolve Docker-local names like `paid-proxy`. Set `PAID_PROXY_EXTERNAL_URL` to the address they can reach.

Recommended options:

- `WireGuard VPN`: best default for NAS/LAN workers
- `SSH tunnel`: simplest for one remote host
- `Cloudflare Tunnel`: useful for VMs without inbound IPs
- `Load balancer + mTLS`: good cloud baseline when the proxy is internet-routable

Examples:

```bash
PAID_PROXY_EXTERNAL_URL=http://10.20.30.40:3000
PAID_PROXY_EXTERNAL_URL=https://paid-proxy.internal.example.com
```

When the remote backend is active, Paid uses this URL for container proxy env vars and firewall proxy allowlisting.

## 4. Configure Paid

Set these environment variables on the Paid control plane:

```bash
CONTAINER_BACKEND=remote
REMOTE_DOCKER_HOST=worker-1.internal:2376
REMOTE_DOCKER_IDENTIFIER=worker-1
REMOTE_DOCKER_CERT=/etc/paid/remote-docker/client-cert.pem
REMOTE_DOCKER_KEY=/etc/paid/remote-docker/client-key.pem
REMOTE_DOCKER_CA=/etc/paid/remote-docker/ca.pem
PAID_PROXY_EXTERNAL_URL=https://paid-proxy.internal.example.com
```

Notes:

- `REMOTE_DOCKER_IDENTIFIER` is what Paid persists into `agent_runs.container_host` and `container_pool_entries.container_host`.
- `REMOTE_DOCKER_HOST` may be `host:port` or a full `tcp://host:port` URL.

## 5. Verify Connectivity

Run:

```bash
bundle exec rake remote_docker:test_connection
```

Expected output is an `OK` ping from the configured remote backend.

## 6. Validate Security Expectations

Confirm all of these before enabling production traffic:

- Docker API only accepts mTLS-authenticated clients
- `PAID_PROXY_EXTERNAL_URL` is encrypted in transit
- Agent containers still receive proxy-issued credentials, not raw provider API keys
- Remote containers join the same expected Docker networks and pass network-policy smoke tests
- The remote host has the `paid-agent:latest` image available, or can pull it

## Operational Notes

- Workspace volumes remain host-local named volumes on the remote daemon.
- Orphan cleanup now scans all registered backends, so local leftovers can still be reaped after moving to remote execution.
- Metrics collection follows `container_host`, so agent-run stats are read from the correct daemon.
