# Scaling Runbook

Operational procedures for scaling Paid up and down, and troubleshooting
scaling-related issues. For architecture and configuration reference, see
[SCALING.md](../SCALING.md).

## Pre-Flight Checklist

Before any scaling operation:

- [ ] Check current resource utilization (CPU, memory, DB connections)
- [ ] Review GoodJob dashboard at `/good_job` for queue health
- [ ] Review Temporal UI for workflow/activity backlogs
- [ ] Note current `max_connections` in PostgreSQL
- [ ] Verify the target configuration is internally consistent

```bash
# Confirm the web server is healthy before making changes
curl -f http://localhost:3000/up

# Verify DB pool size satisfies minimum requirements
bin/rails runner "
  pool = ActiveRecord::Base.connection_pool.size
  puts \"DB_POOL=#{pool}\"
  puts pool >= 10 ? 'OK: pool size sufficient' : 'WARN: pool size may be too low'
"
```

## Scaling Up

### Scenario: Web UI Is Slow

**Symptoms:** High response times, request timeouts, slow page loads.

**Steps:**

1. Check if the bottleneck is the web server or downstream:

   ```bash
   # Check Puma thread utilization
   curl -s http://localhost:3000/up
   ```

2. If Puma is saturated, increase concurrency:

   ```bash
   # Option A: More threads per worker (minor scaling)
   export RAILS_MAX_THREADS=5  # up from 3

   # Option B: More worker processes (major scaling)
   export WEB_CONCURRENCY=auto  # one per CPU

   # Option C: Add another web instance behind the load balancer
   ```

3. After increasing threads or workers, increase `DB_POOL` to match:

   ```bash
   # DB_POOL must be >= RAILS_MAX_THREADS (per worker process)
   export DB_POOL=25
   ```

4. Restart Puma and verify:

   ```bash
   bin/rails restart
   ```

### Scenario: Background Jobs Are Delayed

**Symptoms:** GoodJob queue latency > 30s, jobs visibly backed up in `/good_job`.

**Steps:**

1. Identify which queue is backed up:

   ```sql
   SELECT queue_name, count(*), min(scheduled_at)
   FROM good_jobs
   WHERE finished_at IS NULL
   GROUP BY queue_name
   ORDER BY count DESC;
   ```

2. If running `async_server` mode, switch to external worker:

   ```bash
   export GOOD_JOB_EXECUTION_MODE=external
   # Start dedicated worker process
   bin/jobs
   ```

3. If already external, increase thread pool:

   ```bash
   # Increase total threads
   export GOOD_JOB_MAX_THREADS=15

   # Or increase threads for the specific backed-up queue
   export GOOD_JOB_QUEUES="default:5;maintenance:3;metrics:3;knowledge:3;low_priority:1"
   ```

4. For persistent backlogs, run a second GoodJob worker:

   ```bash
   # On second worker, disable cron to avoid duplicate scheduled jobs
   GOOD_JOB_ENABLE_CRON=false bin/jobs
   ```

### Scenario: Agent Runs Are Queued

**Symptoms:** Temporal activity schedule-to-start latency > 60s, agent runs stuck
in "pending" state.

**Steps:**

1. Check current activity slot utilization in Temporal UI

2. Increase activity slots if Docker host has capacity:

   ```bash
   export TEMPORAL_ACTIVITY_SLOTS=8   # up from 4
   export TEMPORAL_LOCAL_ACTIVITY_SLOTS=4
   ```

3. Verify DB pool can support new slot count:

   ```bash
   # With TEMPORAL_WORKER_MODE=agent (agent activities hold TWO connections each,
   # so the agent-slot count is added twice):
   # DB_POOL >= TEMPORAL_ACTIVITY_SLOTS + TEMPORAL_LOCAL_ACTIVITY_SLOTS + TEMPORAL_ACTIVITY_SLOTS + 2
   # 8 + 4 + 8 + 2 = 22, so DB_POOL must be >= 22 (DB_POOL=20 is NOT enough)
   ```

4. If the Docker host is out of memory for more containers:

   ```bash
   # Check available memory
   free -h

   # Check running containers
   docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Size}}"
   docker stats --no-stream
   ```

5. If host memory is the bottleneck, either:
   - Add another Docker host and Temporal worker pointing to it
   - Reduce per-container memory (if workloads allow)
   - Clean up orphaned containers: the `DockerOrphanCleanupJob` runs every
     5 minutes, but you can trigger it manually from the Rails console

### Scenario: Database Connection Pool Exhausted

**Symptoms:** `ActiveRecord::ConnectionTimeoutError`, connections at or near
`max_connections`.

**Steps:**

1. Check current connection usage:

   ```sql
   -- Total connections
   SELECT count(*) FROM pg_stat_activity;

   -- Connections by application/state
   SELECT application_name, state, count(*)
   FROM pg_stat_activity
   GROUP BY application_name, state
   ORDER BY count DESC;

   -- Check max_connections setting
   SHOW max_connections;
   ```

2. If connections are near the limit:

   ```sql
   -- Increase max_connections (requires restart)
   ALTER SYSTEM SET max_connections = 200;
   ```

3. If individual processes are using too many connections, reduce `DB_POOL`
   per process and compensate with PgBouncer:

   ```bash
   # Install PgBouncer between app and PostgreSQL
   # Set pool_mode = transaction for best multiplexing
   ```

4. Check for connection leaks (connections in `idle` state for long periods):

   ```sql
   SELECT pid, state, query_start, state_change, query
   FROM pg_stat_activity
   WHERE state = 'idle'
     AND state_change < now() - interval '10 minutes';
   ```

## Scaling Down

### When to Scale Down

- Sustained low utilization (< 30% CPU, < 50% memory) for 24+ hours
- Reduced team size or project count
- Cost optimization after a usage spike subsides

### Steps

1. **Remove extra web instances** from the load balancer, then stop them

2. **Reduce GoodJob workers** — stop additional workers (keep at least one with
   `GOOD_JOB_ENABLE_CRON=true`). In-flight jobs will finish gracefully within
   `GOOD_JOB_SHUTDOWN_TIMEOUT`

3. **Reduce Temporal workers** — stop additional workers. Temporal will
   redistribute pending tasks to remaining workers. In-progress activities
   will complete on the stopping worker within the graceful shutdown period

4. **Reduce thread/slot counts** in environment variables and restart:

   ```bash
   export GOOD_JOB_MAX_THREADS=6
   export TEMPORAL_ACTIVITY_SLOTS=4
   export TEMPORAL_WORKER_MODE=agent
   export DB_POOL=20
   ```

5. **Lower PostgreSQL `max_connections`** if it was increased (requires restart)

6. Verify system health after scaling down:
   - GoodJob queue latency remains < 30s
   - Temporal activity backlog is not growing
   - Web response times are acceptable

## Troubleshooting

### Symptom: "PG::ConnectionBad: FATAL: too many connections"

**Cause:** Total connections across all processes exceed PostgreSQL `max_connections`.

**Fix:**

1. Calculate total connections needed (see formulas in SCALING.md)
2. Either increase `max_connections` or reduce `DB_POOL` per process
3. At scale, add PgBouncer for connection multiplexing

### Symptom: Containers OOM-Killed

**Cause:** Agent workload exceeds the 4 GB default memory limit.

**Fix:**

1. Check which containers are being killed:

   ```bash
   docker events --filter event=oom --since 1h
   ```

2. Per-user container memory can be adjusted via `UserSetting#container_memory_bytes`
3. For a system-wide increase, modify the default in `Containers::Provision`

### Symptom: Temporal Worker Fails to Start

**Cause:** Usually a DB pool validation failure.

**Fix:**

1. Check the worker startup log for the specific validation error
2. Common fix: increase `DB_POOL` to satisfy
   the requirement for the mode you are running:
   `agent => TEMPORAL_ACTIVITY_SLOTS + TEMPORAL_LOCAL_ACTIVITY_SLOTS + TEMPORAL_ACTIVITY_SLOTS + 2`,
   `poll => TEMPORAL_POLL_ACTIVITY_SLOTS + TEMPORAL_POLL_LOCAL_ACTIVITY_SLOTS + 2`,
   `both => both pools combined + TEMPORAL_ACTIVITY_SLOTS + 4`
   (agent activities hold two connections each — see docs/WORKER_POOL_TUNING.md).
   `bin/temporal_worker` auto-corrects the pool at boot if `DB_POOL` is below this.

### Symptom: GoodJob Cron Jobs Running Multiple Times

**Cause:** Multiple GoodJob workers with `GOOD_JOB_ENABLE_CRON=true`.

**Fix:**

1. Set `GOOD_JOB_ENABLE_CRON=true` on exactly one worker
2. Set `GOOD_JOB_ENABLE_CRON=false` on all others

### Symptom: Agent Containers Not Cleaned Up

**Cause:** `DockerOrphanCleanupJob` may be stuck or the Docker daemon is unresponsive.

**Fix:**

1. Check if the cleanup job is running:

   ```sql
   SELECT * FROM good_jobs
   WHERE job_class = 'DockerOrphanCleanupJob'
   ORDER BY created_at DESC LIMIT 5;
   ```

2. Manual cleanup:

   ```bash
   # List paid agent containers
   docker ps -a --filter "label=paid.agent_run_id"

   # Remove stopped containers
   docker container prune --filter "label=paid.agent_run_id"
   ```

### Symptom: Disk Space Exhaustion on Docker Host

**Cause:** Container images, volumes, or build cache accumulating.

**Fix:**

1. Check disk usage:

   ```bash
   docker system df
   ```

2. Clean up:

   ```bash
   # Remove unused images (not currently in use by a container)
   docker image prune -a --filter "until=48h"

   # Remove unused volumes
   docker volume prune

   # Nuclear option (removes all unused data)
   docker system prune -a --volumes
   ```

## Validation

After any scaling change, verify the system is healthy:

1. **Verify DB pool configuration:**

   ```bash
   bin/rails runner "
     pool = ActiveRecord::Base.connection_pool.size
     puts \"DB_POOL=#{pool}\"
     puts pool >= 10 ? 'OK: pool size sufficient' : 'WARN: pool size may be too low'
   "
   ```

2. **Check process health:**

   ```bash
   # Web server responding
   curl -f http://localhost:3000/up

   # GoodJob processing
   # Check /good_job dashboard — queue latency should be < 30s

   # Temporal worker connected
   # Check Temporal UI — worker should appear in the task queue
   ```

3. **Monitor for 15 minutes** after the change:
   - DB connection count stable
   - No new error spikes in logs
   - Queue latencies returning to normal
