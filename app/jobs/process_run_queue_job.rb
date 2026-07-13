# frozen_string_literal: true

require "digest/md5"
require "set"
require "temporalio/priority"

class ProcessRunQueueJob < ApplicationJob
  include GoodJob::ActiveJobExtensions::Concurrency

  queue_as :default

  good_job_control_concurrency_with(
    total_limit: 1,
    enqueue_limit: 1,
    key: "process_run_queue"
  )

  # Advisory lock key derived from class name to avoid collisions with other locks.
  ADVISORY_LOCK_KEY = Digest::MD5.hexdigest("ProcessRunQueueJob").to_i(16) % (2**31 - 1)

  # Maximum consecutive workflow start failures before aborting the loop.
  # Prevents cascading failures when Temporal is down.
  MAX_CONSECUTIVE_FAILURES = 3

  # Maximum workflows started per perform invocation. Bounds how long
  # the advisory lock is held and prevents a single job run from
  # monopolizing queue processing under large backlogs.
  MAX_STARTS_PER_PERFORM = 20

  # Maximum loop iterations (including skips) per perform invocation.
  # Prevents unbounded scanning when a large queue has many runs that
  # can't start due to per-user capacity limits.
  MAX_ITERATIONS_PER_PERFORM = 100

  # Temporal priority keys default to the server-configured range 1..5.
  # Keep Paid's richer 9-tier dequeue ordering internal, then compress it
  # onto 5 wire priorities when starting workflows.
  TEMPORAL_PRIORITY_KEYS = {
    manual: 1,
    pr_p1: 2,
    pr_p2: 2,
    pr_p3: 3,
    pr_continue: 3,
    issue_p1: 4,
    issue_p2: 4,
    issue_p3: 5,
    auto_pick: 5
  }.freeze

  def perform
    # Use a PostgreSQL advisory lock to ensure only one job processes the queue at a time.
    # If another instance is already running, this job exits immediately (no-op).
    acquired = ActiveRecord::Base.connection.select_value("SELECT pg_try_advisory_lock(#{ADVISORY_LOCK_KEY})")
    return unless acquired

    begin
      if (github_state = unavailable_github_state)
        log_github_unavailable(github_state)
        return
      end

      consecutive_failures = 0
      starts_count = 0
      iterations = 0
      skipped_ids = Set.new
      blocked_project_ids = Set.new
      blocked_user_ids = Set.new
      # Runner-agnostic queue (#2563): a runner id in this set means
      # "do not pick this runner again on this pass", not "skip the
      # run". Pinned runs whose runner is blocked are rerouted to a
      # healthy alternative; only when no alternative exists is the run
      # added to +skipped_ids+.
      blocked_runner_ids = Set.new
      # Maps reroute resolution context to its resolved alternative:
      # { runner_id:, agent_type:, from_key:, to_key: } or nil when no
      # healthy alternative exists. The cache is scoped to the blocked
      # runner plus the run's resolver inputs (project + goal), because
      # different projects/goals can legitimately resolve to different
      # healthy alternatives.
      reroute_cache = {}
      blocked_account_create_pr_ids = Set.new
      blocked_account_dispatch_ids = Set.new
      started_priority_by_project = {}
      docker_snapshot = nil
      base_reserved_agent_memory_bytes = nil
      started_reserved_agent_memory_bytes = 0

      loop do
        iterations += 1
        break if iterations > MAX_ITERATIONS_PER_PERFORM
        # Peek at the next unclaimed queued run without claiming it, so we can check
        # per-user capacity before claiming. This avoids an unnecessary claim +
        # unclaim cycle (and its associated broadcasts/metrics) for runs that
        # can't start yet.
        next_run = AgentRun.peek_next_queued_run(
          exclude_ids: skipped_ids.to_a,
          exclude_project_ids: blocked_project_ids.to_a,
          exclude_user_ids: blocked_user_ids.to_a,
          exclude_account_create_pr_ids: blocked_account_create_pr_ids.to_a,
          exclude_account_ids: blocked_account_dispatch_ids.to_a
        )

        break unless next_run

        # RDR-032 dequeue-time eligibility recheck: cancel eagerly-seeded
        # runs whose issue lost eligibility after seeding (skip label,
        # paid_state skip, new blocking dependency, closed/completed, ...).
        # Re-enqueue hooks recreate the run if the issue becomes eligible
        # again. Done before capacity/docker checks so ineligible runs
        # don't consume expensive admission work.
        if AgentRuns::RecheckIssueEligibility.call(next_run)
          skipped_ids.add(next_run.id)
          next
        end

        if lower_priority_than_inflight_or_started_project_run?(next_run, started_priority_by_project)
          blocked_project_ids.add(next_run.project_id)
          next
        end

        if (github_state = unavailable_github_state(next_run.project.github_health_endpoint))
          blocked_project_ids.add(next_run.project_id)
          log_github_unavailable(github_state, project_id: next_run.project_id)
          next
        end

        # Resolve the project owner for capacity checks. If the owner
        # can't be resolved, fail the run immediately rather than
        # skipping it — a nil owner would block auto-pick for other
        # users who may have capacity.
        user = next_run.project.effective_owner
        unless user
          if (run = AgentRun.claim_next_queued_run(target_id: next_run.id))
            force_fail_run(run, error: "Cannot resolve project owner for capacity check")
          end
          next
        end

        # The deployment capacity policy drives two decisions: the
        # deployment-wide hard capacity block (Docker memory exhausted) and
        # the auto-mode downgrade. Both require a Docker snapshot round trip
        # the first time current_capacity_policy is called. Resolve it
        # lazily — only once an auto-mode candidate actually needs it — so
        # pure-manual deployments (where the legacy run-count gate already
        # bounds admission) never pay the Docker system_info + per-container
        # stats cost on a queue pass. Once resolved, the memoized decision
        # is reused for every remaining candidate so the deployment-wide
        # capacity gate still applies across users.
        policy_decision = policy_decision_for(user)
        if policy_decision&.capacity_blocked?
          # Docker has no measurable memory headroom for another run (see
          # Capacity::Policy::Decision#capacity_blocked?). This is a
          # deployment-wide signal, not a per-user one, so it takes
          # precedence over run_admission_for's per-user/project accounting —
          # RDR-043 prefers denying new runs over OOM-killing active ones.
          #
          # The deployment-wide gate itself is the cached re-check of
          # policy_decision#capacity_blocked? at the top of every loop
          # iteration (current_capacity_policy memoizes one snapshot per
          # pass, so every subsequent queued run — for any user — is
          # re-blocked here). The blocked_user_ids add below is only a
          # per-user optimization layered on top: it short-circuits this
          # owner's remaining queued runs so a deep backlog for a single
          # user cannot burn the iteration budget one row at a time.
          log_capacity_blocked(user, policy_decision)
          blocked_user_ids.add(user.id)
          next
        end
        forced_admission_mode = nil
        if policy_decision && !policy_decision.auto_allowed && user.settings.run_concurrency_auto?
          # Deployment policy can disable auto mode even when the user's
          # setting remains AUTO. In that case the queue must downgrade
          # admission to manual for this pass instead of consulting Docker.
          # The guard on run_concurrency_auto? avoids a redundant log for
          # users who are already in manual mode (the downgrade is a no-op
          # for them) and keeps current_capacity_policy lazy.
          forced_admission_mode = UserSetting::RUN_CONCURRENCY_MODE_MANUAL
          log_capacity_policy_manual_mode(user, policy_decision)
        end

        admission_uses_auto = forced_admission_mode != UserSetting::RUN_CONCURRENCY_MODE_MANUAL &&
          user.settings.run_concurrency_auto?
        docker_snapshot ||= Capacity::DockerSnapshot.fetch if admission_uses_auto
        admission = run_admission_for(
          next_run,
          user,
          mode: forced_admission_mode,
          docker_snapshot: docker_snapshot,
          reserved_agent_memory_bytes: queue_reserved_agent_memory_bytes(
            user,
            base_reserved_agent_memory_bytes,
            started_reserved_agent_memory_bytes,
            mode: forced_admission_mode
          )
        )
        if admission[:snapshot_available]
          base_reserved_agent_memory_bytes ||= admission[:reserved_agent_memory_bytes].to_i - started_reserved_agent_memory_bytes
        end
        unless admission[:allowed]
          log_capacity_skip(next_run, admission)

          case admission[:reason]
          when "insufficient_docker_capacity"
            blocked_user_ids.add(user.id)
          when "project_hard_ceiling"
            blocked_project_ids.add(next_run.project_id)
          when "create_pr_hard_ceiling"
            blocked_account_create_pr_ids.add(next_run.project.account_id)
          else
            # Exclude the whole owner for the rest of this pass so a deep
            # backlog for a saturated user cannot consume the iteration budget
            # one queued row at a time.
            blocked_user_ids.add(user.id)
          end

          next
        end

        # Resolve a runner for the queued run. Runner-agnostic (auto-pick)
        # runs are late-bound here from the healthy runner pool. Any run whose
        # pinned or just-bound runner is unavailable is *rerouted* to a healthy
        # alternative configured for the same context (agent runs only consider
        # agent-run-enabled runners). Weighting/preference is a soft preference
        # — availability is a hard filter that never blocks work from running.
        if next_run.runner_unbound?
          bound_runner = AgentRuns::BindRunner.call(agent_run: next_run, exclude_runner_ids: blocked_runner_ids)
          unless bound_runner
            log_no_runnable_runner(next_run)
            next
          end
        end

        if next_run.runner_id && blocked_runner_ids.include?(next_run.runner_id)
          # Runner already failed preflight earlier this pass — reroute to a
          # healthy alternative without re-checking (preserves the bulk-skip
          # optimization for runs sharing one bad runner).
          reroute_unavailable_runner(next_run, blocked_runner_ids, skipped_ids, reroute_cache)
          next
        end

        preflight_result = check_runner_preflight(next_run, user)
        if preflight_result && !preflight_result.pass?
          log_preflight_skip(next_run, preflight_result)
          blocked_runner_ids.add(preflight_result.runner_id) if preflight_result.runner_id
          reroute_unavailable_runner(next_run, blocked_runner_ids, skipped_ids, reroute_cache)
          next
        end

        dispatch_decision = dispatch_decision_for(next_run, blocked_account_dispatch_ids)
        next if dispatch_decision == :halt

        # User has capacity, runner passes preflight, and account has create_pr capacity — now atomically claim the run.
        # claim_next_queued_run returns nil if another process claimed or
        # transitioned this run between peek and claim. Skip it and continue
        # processing the queue rather than stopping entirely.
        agent_run = AgentRun.claim_next_queued_run(target_id: next_run.id)
        unless agent_run
          skipped_ids.add(next_run.id)
          next
        end

        result = start_claimed_run(agent_run)
        if result == :budget_blocked
          # Budget-blocked is not a workflow failure and not a real start —
          # skip capacity accounting and continue processing the queue.
          next
        elsif result
          # Stamp the half-open probe only after the run was claimed and its
          # workflow start is known to be proceeding. Stamping earlier would
          # advance last_probe_at even when the probe never dispatched (lost
          # claim or failed start), blocking every remaining queued run for
          # the full probe interval with zero recovery signal.
          mark_dispatched_probe(agent_run) if dispatch_decision == :allow_probe
          consecutive_failures = 0
          starts_count += 1
          started_reserved_agent_memory_bytes += admission[:estimated_memory_per_run_bytes].to_i if docker_snapshot&.[](:available)
          record_started_project_priority(next_run, started_priority_by_project)
          break if starts_count >= MAX_STARTS_PER_PERFORM
        else
          consecutive_failures += 1
          break if consecutive_failures >= MAX_CONSECUTIVE_FAILURES
        end
      end

    ensure
      ActiveRecord::Base.connection.execute("SELECT pg_advisory_unlock(#{ADVISORY_LOCK_KEY})") if acquired
    end
  end

  private

  def unavailable_github_state(endpoint = GithubHealthState::DEFAULT_ENDPOINT)
    state = GithubHealthState.find_by(endpoint: endpoint)
    return unless state

    state.check_circuit_recovery!
    state if state.unavailable?
  end

  def check_runner_preflight(agent_run, user)
    runner = agent_run.runner
    return nil unless runner

    Runners::PreflightCheck.call(runner: runner, user: user)
  end

  # Reroutes a run whose pinned/bound runner is unavailable to a healthy
  # alternative configured for the same context. Weighting is a preference;
  # availability is a hard filter, so a rate-limited / circuit-open runner must
  # never block the run.
  #
  # Resolutions are cached per blocked runner + resolution context so that
  # multiple queued runs with the same resolver inputs share one resolver call
  # without leaking a reroute across projects/goals. When no healthy alternative
  # exists the run's original pin is *restored* (not silently downgraded) and
  # the run is skipped for the rest of this pass — the preferred runner is
  # retried on the next tick.
  def reroute_unavailable_runner(agent_run, blocked_runner_ids, skipped_ids, reroute_cache)
    original_id = agent_run.runner_id
    cache_key = reroute_cache_key(agent_run, original_id)

    if reroute_cache.key?(cache_key)
      cached = reroute_cache[cache_key]
      return skipped_ids.add(agent_run.id) if cached.nil?
      return apply_cached_reroute(agent_run, cached) unless blocked_runner_ids.include?(cached[:runner_id])
    end

    agent_run.update_columns(runner_id: nil)
    if AgentRuns::BindRunner.call(agent_run: agent_run, exclude_runner_ids: blocked_runner_ids)
      cache_reroute_resolution(agent_run, original_id, cache_key, reroute_cache)
    else
      agent_run.update_columns(runner_id: original_id)
      reroute_cache[cache_key] = nil
      skipped_ids.add(agent_run.id)
    end
  end

  def apply_cached_reroute(agent_run, cached)
    agent_run.update_columns(runner_id: cached[:runner_id], agent_type: cached[:agent_type])
    log_runner_reroute(agent_run, cached[:from_key], cached[:to_key])
  end

  def cache_reroute_resolution(agent_run, original_id, cache_key, reroute_cache)
    from_key = runner_routing_key(original_id)
    to_key = runner_routing_key(agent_run.runner_id)
    reroute_cache[cache_key] = {
      runner_id: agent_run.runner_id, agent_type: agent_run.agent_type,
      from_key: from_key, to_key: to_key
    }
    log_runner_reroute(agent_run, from_key, to_key)
  end

  def reroute_cache_key(agent_run, original_id)
    [ original_id, agent_run.project_id, agent_run.goal ]
  end

  def runner_routing_key(runner_id)
    Runner.find_by(id: runner_id)&.routing_key
  end

  def log_runner_reroute(agent_run, from_key, to_key)
    return unless from_key && to_key

    agent_run.log_runner_switch!(from_key, to_key, "dispatch_reroute")
  end

  def log_preflight_skip(agent_run, result)
    Rails.logger.info(
      message: "process_run_queue.preflight_skip",
      agent_run_id: agent_run.id,
      runner_id: result.runner_id,
      reason: result.reason,
      project_id: agent_run.project_id
    )
  end

  def log_github_unavailable(state, project_id: nil)
    payload = {
      message: "process_run_queue.skipped_github_unavailable",
      reason: state.rate_limited? ? "rate_limited" : "circuit_open",
      available_at: state.rate_limited_until&.iso8601
    }
    payload[:project_id] = project_id if project_id
    Rails.logger.info(payload)
  end

  # Late-binding could not resolve any runnable runner for the queued
  # run. The run stays queued for a later pass — once a healthy runner
  # is available, the resolver will pair it. This is the
  # runner-agnostic-queue equivalent of the pre-#2563 "no runner
  # available, schedule retry" path on the enqueue side.
  def log_no_runnable_runner(agent_run)
    Rails.logger.info(
      message: "process_run_queue.no_runnable_runner",
      agent_run_id: agent_run.id,
      project_id: agent_run.project_id,
      intended_agent_type: agent_run.agent_type
    )
  end

  def run_admission_for(agent_run, user, mode:, docker_snapshot:, reserved_agent_memory_bytes:)
    Capacity::RunAdmission.call(
      user: user,
      project: agent_run.project,
      goal: agent_run.goal,
      mode: mode,
      docker_snapshot: docker_snapshot,
      reserved_agent_memory_bytes: reserved_agent_memory_bytes
    )
  end

  def log_capacity_blocked(user, policy_decision)
    Rails.logger.info(
      message: "process_run_queue.capacity_blocked",
      user_id: user.id,
      mode: policy_decision.mode,
      environment: policy_decision.environment,
      reasons: policy_decision.blocked_reasons.map(&:code)
    )
  end

  def log_capacity_policy_manual_mode(user, policy_decision)
    Rails.logger.info(
      message: "process_run_queue.capacity_policy_manual_mode",
      user_id: user.id,
      mode: policy_decision.mode,
      environment: policy_decision.environment,
      reasons: policy_decision.blocked_reasons.map(&:code)
    )
  end

  def queue_reserved_agent_memory_bytes(user, base_reserved_agent_memory_bytes, started_reserved_agent_memory_bytes, mode:)
    effective_mode = mode || user.settings.run_concurrency_mode
    return unless effective_mode == UserSetting::RUN_CONCURRENCY_MODE_AUTO
    return if base_reserved_agent_memory_bytes.nil? && started_reserved_agent_memory_bytes.zero?

    base_reserved_agent_memory_bytes.to_i + started_reserved_agent_memory_bytes
  end

  def log_capacity_skip(agent_run, admission)
    Rails.logger.info(
      message: "process_run_queue.capacity_denied",
      agent_run_id: agent_run.id,
      project_id: agent_run.project_id,
      goal: agent_run.goal,
      reason: admission[:reason],
      mode: admission[:mode],
      available_slots: admission[:available_slots],
      effective_max_concurrent_runs: admission[:effective_max_concurrent_runs],
      available_memory_bytes: admission[:available_memory_bytes],
      estimated_memory_per_run_bytes: admission[:estimated_memory_per_run_bytes],
      reserved_agent_memory_bytes: admission[:reserved_agent_memory_bytes],
      docker_reason: admission[:docker_reason],
      degraded: admission[:degraded] == true
    )
  end

  # Returns the dispatch circuit-breaker decision for the next queued run:
  #   :dispatch    — breaker closed; dispatch normally
  #   :allow_probe  — breaker half-open; this run is a probe candidate, to be
  #                   recorded only once it has actually dispatched (see below)
  #   :halt         — breaker open or recently probed; block the run
  # The decision (rather than a boolean) is returned so the caller can stamp
  # the probe after the run is claimed and started. Stamping earlier — inside
  # this check — would advance last_probe_at even when the probe never
  # dispatched, blocking recovery for the full probe interval.
  def dispatch_decision_for(agent_run, blocked_account_dispatch_ids)
    account = agent_run.project.account
    # Once an account is halted in this pass, every remaining queued run for
    # it must stay blocked — returning :dispatch here would let the next run
    # bypass the breaker and dispatch after only a single run was skipped.
    return :halt if blocked_account_dispatch_ids.include?(account.id)

    decision = ::AgentRuns::DispatchCircuitBreaker.probe_decision(account)

    if decision == :halt
      blocked_account_dispatch_ids.add(account.id)
      Rails.logger.info(
        message: "process_run_queue.dispatch_halted",
        agent_run_id: agent_run.id,
        account_id: account.id
      )
    elsif decision == :allow_probe
      Rails.logger.info(
        message: "process_run_queue.dispatch_probe",
        agent_run_id: agent_run.id,
        account_id: account.id
      )
    end
    decision
  end

  # Records the half-open probe on the breaker only after the run was
  # actually claimed and its workflow start is known to be proceeding.
  def mark_dispatched_probe(agent_run)
    ::AgentRuns::DispatchCircuitBreaker
      .new(agent_run.project.account)
      .mark_probe_dispatched!(agent_run_id: agent_run.id)
  end

  def record_started_project_priority(agent_run, started_priority_by_project)
    priority = queue_priority_for(agent_run)
    existing = started_priority_by_project[agent_run.project_id]
    started_priority_by_project[agent_run.project_id] = priority if existing.nil? || priority < existing
  end

  # Blocks a queued run from starting when the same project still has
  # higher-priority work in flight — whether already running or merely
  # claimed-but-not-yet-started — or started higher-priority work earlier in
  # this pass. This keeps priority strict within a project: e.g. a P2 must
  # wait while any P1 for the project is running or queued-and-claimed.
  def lower_priority_than_inflight_or_started_project_run?(agent_run, started_priority_by_project)
    current_priority = queue_priority_for(agent_run)
    started_priority = started_priority_by_project[agent_run.project_id]
    return true if started_priority && current_priority > started_priority

    AgentRun
      .inflight_with_priority
      .where(project_id: agent_run.project_id)
      .where("#{AgentRun::QUEUE_PRIORITY_CASE_SQL} < ?", current_priority)
      .exists?
  end

  def queue_priority_for(agent_run)
    value = agent_run.read_attribute(:queue_priority)
    return value.to_i unless value.nil?

    AgentRun::QUEUE_PRIORITIES.keys.index(agent_run.queue_priority_tier) || AgentRun::QUEUE_PRIORITIES.size
  end

  def start_claimed_run(agent_run)
    ConfigurationBundles::AssignToRun.call(agent_run: agent_run) if agent_run.configuration_bundle.blank?

    budget_result = CostBudgets::Check.call(agent_run.project)
    unless budget_result[:allowed]
      agent_run.fail!(error: "Budget enforcement: #{budget_result[:reason]}")
      Rails.logger.warn(
        message: "process_run_queue.budget_blocked",
        agent_run_id: agent_run.id,
        reason: budget_result[:reason]
      )
      return :budget_blocked
    end

    workflow_input = {
      project_id: agent_run.project_id,
      agent_type: agent_run.agent_type,
      agent_run_id: agent_run.id,
      goal: agent_run.goal
    }
    workflow_input[:issue_id] = agent_run.issue_id if agent_run.issue_id
    workflow_input[:custom_prompt] = agent_run.custom_prompt if agent_run.custom_prompt.present?
    workflow_input[:source_pull_request_number] = agent_run.source_pull_request_number if agent_run.source_pull_request_number

    workflow_id = "queued-#{agent_run.project_id}-#{agent_run.id}-#{Time.current.to_i}"

    # Write the planned workflow_id before starting the workflow so
    # StaleRunDetectorJob can cancel an orphaned workflow even if the
    # process crashes between start_workflow and the DB write.
    agent_run.update_columns(temporal_workflow_id: workflow_id)

    # Keep temporal_workflow_id set on failure — if start_workflow raises
    # due to a network timeout, the workflow may have started server-side.
    # Leaving the ID allows StaleRunDetectorJob to find and cancel the
    # potentially-orphaned workflow rather than losing track of it.
    Paid.temporal_client.start_workflow(
      Workflows::AgentExecutionWorkflow,
      workflow_input,
      id: workflow_id,
      task_queue: Paid.agent_task_queue,
      priority: temporal_priority_for(agent_run)
    )

    Rails.logger.info(
      message: "process_run_queue.started_queued_run",
      agent_run_id: agent_run.id,
      workflow_id: workflow_id
    )
    true
  rescue => e
    force_fail_run(agent_run, error: "Failed to start workflow: #{e.message}")
    Rails.logger.error(
      message: "process_run_queue.start_failed",
      agent_run_id: agent_run.id,
      error: e.message
    )
    false
  end

  # Queue-start failures are infrastructure failures, not business-rule
  # transitions. Skip validations so unrelated model state cannot strand
  # the run in queued, but still save normally so after_commit hooks
  # broadcast the terminal status and enqueue finished-run followups.
  # Bundled with #1041 because knowledge fallback testing surfaced this
  # stranded-run bug; splitting would leave the failure path broken on main.
  def force_fail_run(agent_run, error:)
    agent_run.assign_attributes(
      status: "failed",
      completed_at: Time.current,
      error_message: error,
      duration_seconds: agent_run.duration
    )
    agent_run.save!(validate: false)
  end

  # Resolves the Capacity::Policy decision for the current candidate only
  # when it can influence the admission outcome. The first resolution
  # performs a Docker system_info + per-container stats round trip via
  # current_capacity_policy; to avoid paying that on every queue pass for
  # pure-manual deployments — where the legacy tenant_max_concurrent_runs
  # gate fully bounds admission — the snapshot is fetched lazily, the first
  # time an auto-mode candidate is encountered. Once the decision is cached
  # for the pass (including the nil fail-safe), every remaining candidate
  # reuses it so the deployment-wide capacity gate still applies across
  # users.
  def policy_decision_for(user)
    return current_capacity_policy if defined?(@current_capacity_policy)

    current_capacity_policy if user.settings.run_concurrency_auto?
  end

  # Resolves a Capacity::Policy decision for the current process pass.
  # The snapshot is fetched once and cached on the job instance so every
  # queued-run candidate reuses the same decision without re-reading
  # Docker. When the policy cannot be resolved the method returns nil
  # and the caller falls back to legacy behavior — fail-safe default
  # rather than fail-loud: leaving the queue running with stable manual
  # limits is better than halting dispatch.
  def current_capacity_policy
    return @current_capacity_policy if defined?(@current_capacity_policy)

    snapshot = Capacity::DockerSnapshot.call
    @current_capacity_policy = Capacity::Policy.call(snapshot: snapshot, ci: ENV["CI"].present?)
  rescue => e
    Rails.logger.warn(
      message: "process_run_queue.capacity_policy_unavailable",
      error: e.class.name,
      detail: e.message,
      reason: Capacity::BlockedReason[:policy_unknown].code
    )
    @current_capacity_policy = nil
  end

  def temporal_priority_for(agent_run)
    Temporalio::Priority.new(
      priority_key: TEMPORAL_PRIORITY_KEYS.fetch(agent_run.queue_priority_tier),
      fairness_key: temporal_fairness_key_for(agent_run)
    )
  end

  def temporal_fairness_key_for(agent_run)
    agent_run.project.account_id.to_s
  end
end
