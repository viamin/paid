# Docker Swarm Setup

This guide configures Paid to provision agent containers through a Docker Swarm manager while still running the agents on individual Swarm nodes.

## Requirements

- Docker Engine 24+ on every Swarm node
- Swarm mode initialized and at least one manager available
- The Paid app can reach the Swarm manager Docker API
- Every worker that may run agents exposes its Docker API with the same client TLS trust chain as the manager
- The `paid_agent` and `paid_internal` networks exist as Swarm overlay networks

## 1. Initialize Swarm

On the first manager:

```bash
docker swarm init --advertise-addr <manager-ip>
```

Join each worker with the token Docker prints:

```bash
docker swarm join --token <worker-token> <manager-ip>:2377
```

## 2. Expose the Docker API Safely

Paid needs:

- Manager API access for service scheduling
- Worker API access for `docker exec`, stats, logs, and volume cleanup on the node where a task lands

Use mutual TLS on every node. A typical daemon configuration is:

```json
{
  "hosts": ["unix:///var/run/docker.sock", "tcp://0.0.0.0:2376"],
  "tls": true,
  "tlsverify": true,
  "tlscacert": "/etc/docker/pki/ca.pem",
  "tlscert": "/etc/docker/pki/server-cert.pem",
  "tlskey": "/etc/docker/pki/server-key.pem"
}
```

Paid reuses the same client certs for the manager and workers. Set:

```bash
export CONTAINER_BACKEND=swarm
export SWARM_MANAGER_HOST=https://swarm-manager.internal:2376
export DOCKER_CERT_PATH=/run/secrets/docker-client
```

If the Docker API is reachable on a different port, also set:

```bash
export SWARM_NODE_DOCKER_PORT=2376
```

## 3. Create Overlay Networks

Create the restricted agent network and the unrestricted infrastructure network as attachable overlays:

```bash
docker network create \
  --driver overlay \
  --attachable \
  --subnet 172.28.0.0/16 \
  paid_agent

docker network create \
  --driver overlay \
  --attachable \
  paid_internal
```

`paid-proxy` must be attached to the same overlay network that agent containers use so Swarm DNS resolves it from every node.

## 4. Label Nodes for Placement

Examples:

```bash
docker node update --label-add paid.agent=true worker-1
docker node update --label-add paid.agent=true worker-2
docker node update --label-add paid.gpu=true gpu-worker-1
docker node update --label-add paid.memory=high worker-2
docker node update --label-add paid.memory=low worker-3
docker node update --label-add paid.docker_host=worker-1.internal worker-1
```

`paid.docker_host` is optional but recommended when the worker should be reached on a hostname that differs from the node status IP.

Configure placement rules in Paid with comma-separated environment variables:

```bash
export SWARM_PLACEMENT_CONSTRAINTS='node.labels.paid.agent == true,node.labels.paid.memory != low'
export SWARM_PLACEMENT_PREFERENCES='node.labels.paid.zone'
```

Common patterns:

- Prefer GPU nodes: `node.labels.paid.gpu == true`
- Keep agents off low-memory nodes: `node.labels.paid.memory != low`
- Restrict to dedicated agent workers: `node.labels.paid.agent == true`

## 5. Backend Behavior

When `CONTAINER_BACKEND=swarm`:

- Paid creates a one-replica Swarm service per agent run
- Restart policy is `none` so task failure is visible to Paid
- `agent_runs.container_id` stores the Swarm service id
- `agent_runs.container_host` stores the Swarm node hostname where the task landed
- Overlay networking provides `paid-proxy` DNS on every node

## 6. Health Checks and Failure Detection

Paid considers only Swarm nodes with:

- `Spec.Availability == active`
- `Status.State == ready`

Failed tasks remain detectable because the Swarm backend refreshes state from the current task and records the landing node separately from the backend identifier.

Operational checks:

```bash
docker node ls
docker service ls
docker service ps <service-id>
docker service inspect <service-id>
```

If a node goes down, task cleanup may fail until the node returns. Paid will still record the node hostname and surface the task state from Swarm.

## 7. Limitations

- Host bind mounts must exist on every worker that can run agent services
- Explicit host worktree mounts are not a good fit for multi-host Swarm; use the default named-volume workspace flow
- Worker Docker APIs must be reachable from the Paid app, not just the manager
