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
  QUEUE_PARKING_EXECUTION_CONTROL_SCOPES = %w[global account project].freeze

  # Reason suffixes InfrastructureSpendGuard uses for a breach (see
  # Capacity::InfrastructureSpendGuard#evaluate); mirrors how
  # Capacity::RunAdmission#apply_infrastructure_safety_rails distinguishes a
  # spend-driven denial from a capacity-driven one.
  SPEND_DENIAL_REASON_PATTERN = /_infra_spend_(?:hourly|daily)_limit_exceeded\z/

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

      Capacity::InfrastructureSpendGuard.recover_global_daily_threshold!

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
      blocked_account_ids = Set.new
      blocked_account_create_pr_ids = Set.new
      blocked_account_dispatch_ids = Set.new
      execution_control_snapshot = execution_control_snapshot_for_queue
      docker_snapshots_by_host = {}
      base_reserved_agent_memory_bytes_by_host = {}
      started_reserved_agent_memory_bytes_by_host = Hash.new(0)
      admission_snapshot = Capacity::AdmissionSnapshot.capture(
        window_seconds: Capacity::InfrastructureLimits.current[:provisioning_rate_window_seconds]
      )

      loop do
        iterations += 1
        break if iterations > MAX_ITERATIONS_PER_PERFORM
        # Peek at the next unclaimed queued run without claiming it, so we can check
        # per-user capacity before claiming. This avoids an unnecessary claim +
        # unclaim cycle (and its associated broadcasts/metrics) for runs that
        # can't start yet.
        next_run = next_queued_run_for_scheduler(
          skipped_ids:,
          blocked_project_ids:,
          blocked_user_ids:,
          blocked_account_ids:,
          blocked_account_create_pr_ids:,
          blocked_account_dispatch_ids:
        )

        break unless next_run

        # RDR-032 dequeue-time eligibility recheck: cancel eagerly-seeded
        # runs whose issue lost eligibility after seeding (skip label,
        # paid_state skip, new blocking dependency, closed/completed, ...).
        # Re-enqueue hooks recreate the run if the issue becomes eligible
        # again. Done before capacity/docker checks so ineligible runs
        # don't consume expensive admission work.
        # @spec EAGER-QUEUE-005
        if AgentRuns::RecheckIssueEligibility.call(next_run)
          skipped_ids.add(next_run.id)
          next
        end

        if (github_state = unavailable_github_state(next_run.project.github_health_endpoint))
          blocked_project_ids.add(next_run.project_id)
          log_github_unavailable(github_state, project_id: next_run.project_id)
          next
        end

        # @spec EXEC-DISABLE-002 — global/account/project controls park
        # unconditionally, independent of capacity, host, or runner. Checked
        # here, before admission, so parked runs skip the entire backend
        # scheduling / host placement / runner binding pipeline instead of
        # paying for it only to be parked afterward. This also keeps
        # runner-unbound runs unbound: AgentRuns::BindRunner (further down)
        # persists a runner_id as a side effect of resolution, which would
        # otherwise pin a parked run to a runner chosen before the control
        # cleared rather than one re-resolved at dispatch time.
        execution_control = queue_parking_execution_control_for(next_run, execution_control_snapshot)
        if execution_control
          park_run_for_execution_control(next_run, execution_control)
          skipped_ids.add(next_run.id)
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

        host_selection = Containers::BackendScheduler.call(agent_run: next_run)
        unless host_selection.candidate_hosts.any?
          if host_selection.requirements_error.present?
            force_fail_run(next_run, error: host_selection.requirements_error)
            skipped_ids.add(next_run.id)
            next
          end

          log_host_selection_skip(next_run, host_selection)
          skipped_ids.add(next_run.id)
          next
        end

        selected_host, admission, host_placement_decision = select_host_admission(
          agent_run: next_run,
          user: user,
          host_selection: host_selection,
          forced_admission_mode: forced_admission_mode,
          docker_snapshots_by_host: docker_snapshots_by_host,
          base_reserved_agent_memory_bytes_by_host: base_reserved_agent_memory_bytes_by_host,
          started_reserved_agent_memory_bytes_by_host: started_reserved_agent_memory_bytes_by_host,
          admission_snapshot: admission_snapshot
        )
        unless admission[:allowed]
          ExecutionAuditEvents::Lifecycle.record(
            event_name: "execution.rejected",
            actor_id: "process_run_queue",
            agent_run: next_run,
            backend: selected_host,
            metadata: {
              reason: admission[:reason],
              rate_limited_until: admission[:rate_limited_until]&.iso8601,
              selected_host: selected_host
            }
          )
          log_capacity_skip(next_run, admission, host_selection: host_selection, host_placement_decision: host_placement_decision)

          case admission[:reason]
          when "global_hard_ceiling"
            # Global limit exhausted — no further runs can start this pass
            # regardless of user/project/host. Break rather than next to avoid
            # needlessly scanning the rest of the queue.
            break
          when "insufficient_docker_capacity"
            blocked_user_ids.add(user.id)
          when "host_hard_ceiling"
            skipped_ids.add(next_run.id)
          when "project_hard_ceiling"
            blocked_project_ids.add(next_run.project_id)
          when "create_pr_hard_ceiling"
            blocked_account_create_pr_ids.add(next_run.project.account_id)
          when "global_provisioning_rate_limit"
            park_run_for_capacity(next_run, admission[:rate_limited_until], admission[:reason])
            break
          when "account_provisioning_rate_limit"
            park_run_for_capacity(next_run, admission[:rate_limited_until], admission[:reason])
            blocked_account_ids.add(next_run.project.account_id)
          when "project_provisioning_rate_limit"
            park_run_for_capacity(next_run, admission[:rate_limited_until], admission[:reason])
            blocked_project_ids.add(next_run.project_id)
          when ->(reason) { spend_capacity_denial?(reason) && admission[:rate_limited_until].present? }
            park_run_for_capacity(next_run, admission[:rate_limited_until], admission[:reason])
            block_scope_for_spend_denial(
              admission[:reason],
              project_id: next_run.project_id,
              account_id: next_run.project.account_id,
              blocked_project_ids: blocked_project_ids,
              blocked_account_ids: blocked_account_ids
            )
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
          bound_runner = AgentRuns::BindRunner.call(
            agent_run: next_run,
            exclude_runner_ids: blocked_runner_ids,
            disabled_runner_ids: execution_control_snapshot[:disabled_runner_ids]
          )
          unless bound_runner
            # @spec RUNNER-SCHED-008: when all eligible runners are blocked by
            # time-window restrictions, park the run until the earliest window
            # opens so StaleRunDetectorJob recovers it automatically.
            park_until = Runners::TimeWindowPark.call(next_run, exclude_runner_ids: blocked_runner_ids)
            if park_until
              park_run_for_time_window(next_run, park_until)
            else
              log_no_runnable_runner(next_run)
            end
            next
          end
        end

        if next_run.runner_id && blocked_runner_ids.include?(next_run.runner_id)
          # Runner already failed preflight earlier this pass — reroute to a
          # healthy alternative without re-checking (preserves the bulk-skip
          # optimization for runs sharing one bad runner).
          reroute_unavailable_runner(next_run, blocked_runner_ids, skipped_ids, reroute_cache,
            disabled_runner_ids: execution_control_snapshot[:disabled_runner_ids])
          next
        end

        preflight_result = check_runner_preflight(next_run, user,
          disabled_runner_ids: execution_control_snapshot[:disabled_runner_ids])
        if preflight_result && !preflight_result.pass?
          log_preflight_skip(next_run, preflight_result)
          blocked_runner_ids.add(preflight_result.runner_id) if preflight_result.runner_id
          reroute_unavailable_runner(next_run, blocked_runner_ids, skipped_ids, reroute_cache,
            disabled_runner_ids: execution_control_snapshot[:disabled_runner_ids])
          next
        end

        # Runner spend is enforced only after the run has a concrete runner for
        # this dispatch attempt. That means late-bound auto-pick runs flow
        # through the guard immediately below, while rerouted runs are re-queued
        # and re-enter the same guard on the next loop iteration before they can
        # dispatch on the newly bound runner.
        if (runner_spend_result = runner_infrastructure_spend_result(next_run, selected_host))
          log_runner_spend_skip(next_run, runner_spend_result)
          blocked_runner_ids.add(next_run.runner_id) if next_run.runner_id
          reroute_unavailable_runner(next_run, blocked_runner_ids, skipped_ids, reroute_cache,
            disabled_runner_ids: execution_control_snapshot[:disabled_runner_ids],
            available_at: runner_spend_result[:rate_limited_until],
            park_reason: runner_spend_result[:reason])
          next
        end

        dispatch_decision = dispatch_decision_for(next_run, blocked_account_dispatch_ids)
        next if dispatch_decision == :halt

        # User has capacity, runner passes preflight, and account has create_pr capacity — now atomically claim the run.
        # claim_next_queued_run returns nil if another process claimed or
        # transitioned this run between peek and claim. Skip it and continue
        # processing the queue rather than stopping entirely.
        begin
          agent_run = AgentRun.claim_next_queued_run(target_id: next_run.id)
        rescue ActiveRecord::RecordInvalid => e
          # The run is in a state that can never pass validation (e.g. an
          # agent_type that drifted out of AGENT_TYPES), so claiming it — which
          # calls update! and re-validates — raises RecordInvalid. Force-fail it
          # so it leaves the queue instead of stalling every dispatch tick
          # behind one unclaimable run.
          force_fail_run(next_run, error: "Unclaimable run: #{e.record.errors.full_messages.to_sentence}")
          skipped_ids.add(next_run.id)
          next
        end

        unless agent_run
          skipped_ids.add(next_run.id)
          next
        end

        # RDR-048 (#2947): do not persist container_host here. The planned
        # placement is forwarded into the workflow input and then into
        # Provision/ProvisionContainerActivity as a separate kwarg so the
        # container_host column is updated *only* once a backend creates
        # or claims a real resource. This avoids leaving the run pointing
        # at a host that never owned it when the budget check, workflow
        # start, or pool/provision step fails after this point.
        log_host_selection(agent_run, host_selection, selected_host, admission, host_placement_decision: host_placement_decision)
        result = start_claimed_run(
          agent_run,
          planned_container_host: selected_host,
          host_placement_decision: host_placement_decision
        )
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
          if admission[:snapshot_available]
            base_reserved_agent_memory_bytes_by_host[selected_host] ||= (
              admission[:reserved_agent_memory_bytes].to_i - started_reserved_agent_memory_bytes_by_host[selected_host]
            )
          end
          started_reserved_agent_memory_bytes_by_host[selected_host] += admission[:estimated_memory_per_run_bytes].to_i
          admission_snapshot.record_started_run(
            agent_run,
            host: selected_host,
            started_at: agent_run.provisioning_started_at || Time.current
          )
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

  def check_runner_preflight(agent_run, user, disabled_runner_ids: nil)
    runner = agent_run.runner
    return nil unless runner

    Runners::PreflightCheck.call(runner: runner, user: user, disabled_runner_ids: disabled_runner_ids)
  end

  # @spec EXEC-DISABLE-002 — only global/account/project controls park queued
  # runs before claim. Runner/backend controls are enforced later in the
  # preflight and placement paths so reroute/late-binding semantics still apply.
  def queue_parking_execution_control_for(agent_run, execution_control_snapshot)
    control = [
      execution_control_snapshot[:global],
      execution_control_snapshot[:accounts][agent_run.project.account_id],
      execution_control_snapshot[:projects][agent_run.project_id]
    ].compact.max_by(&:priority)
    return unless control

    control if QUEUE_PARKING_EXECUTION_CONTROL_SCOPES.include?(control.scope)
  end

  def execution_control_snapshot_for_queue
    controls = ExecutionControl.enabled.where(scope: ExecutionControl::SCOPES).to_a

    {
      global: controls.find { |control| control.scope == "global" },
      accounts: controls.select { |control| control.scope == "account" }.index_by(&:account_id),
      projects: controls.select { |control| control.scope == "project" }.index_by(&:project_id),
      disabled_runner_ids: controls.filter_map { |control| control.runner_id if control.scope == "runner" }.to_set
    }
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
  #
  # @spec RUNNER-SCHED-008 — when no alternative is found because *every*
  # eligible runner is blocked by a time-window restriction, the run is parked
  # (rate_limited with +rate_limited_until+) until the earliest window opens
  # instead of being restored and churned on every queue pass. The parked_until
  # time is cached alongside reroute resolutions so runs sharing a reroute
  # context park without another resolver call.
  def reroute_unavailable_runner(agent_run, blocked_runner_ids, skipped_ids, reroute_cache, disabled_runner_ids: nil,
    available_at: nil, park_reason: nil)
    original_id = agent_run.runner_id
    cache_key = reroute_cache_key(agent_run, original_id)

    if reroute_cache.key?(cache_key)
      cached = reroute_cache[cache_key]
      return skipped_ids.add(agent_run.id) if cached.nil?
      if cached.key?(:parked_until)
        return park_run_for_capacity(agent_run, cached[:parked_until], cached[:park_reason]) if cached[:park_reason].present?

        return park_run_for_time_window(agent_run, cached[:parked_until])
      end
      return apply_cached_reroute(agent_run, cached) unless blocked_runner_ids.include?(cached[:runner_id])
    end

    agent_run.update_columns(runner_id: nil)
    if AgentRuns::BindRunner.call(agent_run: agent_run, exclude_runner_ids: blocked_runner_ids,
                                    disabled_runner_ids: disabled_runner_ids)
      cache_reroute_resolution(agent_run, original_id, cache_key, reroute_cache)
    else
      # @spec RUNNER-SCHED-008: when every alternative is time-window-blocked,
      # park the run until the earliest window opens so StaleRunDetectorJob
      # recovers it automatically, instead of restoring the pin and churning.
      #
      # Intentionally passes NO exclude list: the reroute no-alternative path is
      # reached because the pinned runner just failed preflight (time_window_blocked)
      # and was added to +blocked_runner_ids+. Excluding it here would hide it from
      # the "all runners blocked" check, so a user whose only runner carries a
      # time restriction would never park — they'd churn every pass. Rate-limited
      # runners in +blocked_runner_ids+ are NOT time-window-blocked, so counting
      # them (by not excluding) correctly suppresses parking while they recover.
      park_until = available_at || Runners::TimeWindowPark.call(agent_run)
      agent_run.update_columns(runner_id: original_id)
      if park_until
        if park_reason.present?
          park_run_for_capacity(agent_run, park_until, park_reason)
        else
          park_run_for_time_window(agent_run, park_until)
        end
        reroute_cache[cache_key] = { parked_until: park_until, park_reason: park_reason }
      else
        reroute_cache[cache_key] = nil
        skipped_ids.add(agent_run.id)
      end
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

  def runner_infrastructure_spend_result(agent_run, selected_host)
    return unless agent_run.runner

    result = Capacity::InfrastructureSpendGuard.call(
      account: agent_run.project.account,
      project: agent_run.project,
      agent_run: agent_run,
      runner: agent_run.runner,
      selected_host: selected_host
    )
    return if result[:allowed]
    return unless result[:spend_scope] == "runner"

    result
  end

  def log_runner_spend_skip(agent_run, result)
    Rails.logger.info(
      message: "process_run_queue.runner_spend_skip",
      agent_run_id: agent_run.id,
      project_id: agent_run.project_id,
      runner_id: agent_run.runner_id,
      reason: result[:reason],
      rate_limited_until: result[:rate_limited_until]&.iso8601
    )
  end

  def park_run_for_execution_control(agent_run, control)
    ExecutionControls::RunImpact.new(control: control).park_run!(agent_run)
    Rails.logger.info(
      message: "process_run_queue.execution_disabled",
      execution_control_id: control.id,
      scope: control.scope,
      mode: control.mode,
      agent_run_id: agent_run.id,
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

  # @spec RUNNER-SCHED-008
  # Atomically transitions a queued run to rate_limited with
  # rate_limited_until set to the earliest time-window-open, so
  # StaleRunDetectorJob re-queues it automatically when the window passes.
  # Does NOT reset stale_requeue_count: that counter tracks how many times
  # the run has cycled through rate_limited recovery, and resetting it here
  # would defeat the MAX_RATE_LIMITED_REQUEUES exhaustion guard in
  # StaleRunDetectorJob#recover_rate_limited_run — a misconfigured runner
  # (e.g. all 24h blocked) would loop forever without ever failing.
  def park_run_for_time_window(agent_run, available_at)
    # Only transition an unclaimed queued run (temporal_workflow_id IS NULL).
    # Using nil rather than `where.not(temporal_workflow_id: CLAIMED_SENTINEL)`
    # because SQL `NULL != 'claimed'` evaluates to NULL (not TRUE), which would
    # exclude every unclaimed run and silently never park — defeating the guard.
    count = AgentRun.where(id: agent_run.id, status: "queued", temporal_workflow_id: nil)
      .update_all(
        status: "rate_limited",
        rate_limited_until: available_at,
        updated_at: Time.current
      )

    if count.positive?
      Rails.logger.info(
        message: "process_run_queue.time_window_parked",
        agent_run_id: agent_run.id,
        project_id: agent_run.project_id,
        rate_limited_until: available_at.iso8601
      )
    end
  end

  def park_run_for_capacity(agent_run, available_at, reason)
    return if available_at.blank?

    parked = false
    agent_run.with_lock do
      agent_run.reload
      next unless agent_run.status == "queued" && agent_run.temporal_workflow_id.nil?

      metadata = agent_run.external_metadata.deep_dup
      metadata["capacity_park_reason"] = reason
      agent_run.update_columns(
        status: "rate_limited",
        rate_limited_until: available_at,
        external_metadata: metadata,
        updated_at: Time.current
      )
      parked = true
    end

    return unless parked

    Rails.logger.info(
      message: "process_run_queue.capacity_parked",
      agent_run_id: agent_run.id,
      project_id: agent_run.project_id,
      reason: reason,
      rate_limited_until: available_at.iso8601
    )
  end

  # build_host_admission_evaluations calls this once per *candidate* host, so
  # it always previews admission (no infrastructure-spend side effects — see
  # Capacity::RunAdmission.preview). Only the host that select_host_admission
  # ultimately chooses gets a real, side-effecting spend check, applied once
  # by finalize_infrastructure_spend!.
  def run_admission_for(agent_run, user, mode:, docker_snapshot:, reserved_agent_memory_bytes:, selected_host:, selected_host_limit:,
    admission_snapshot:)
    Capacity::RunAdmission.preview(
      user: user,
      project: agent_run.project,
      goal: agent_run.goal,
      agent_run: agent_run,
      mode: mode,
      docker_snapshot: docker_snapshot,
      reserved_agent_memory_bytes: reserved_agent_memory_bytes,
      selected_host: selected_host,
      selected_host_limit: selected_host_limit,
      admission_snapshot: admission_snapshot
    )
  end

  # Entry point used by #perform. Resolves the winning host/admission/decision
  # via #resolve_host_admission — which may speculatively preview several
  # candidate hosts — then finalizes the infrastructure-spend check for real,
  # exactly once, against only the host that was actually chosen. See
  # #finalize_infrastructure_spend! for why this two-step split exists.
  def select_host_admission(agent_run:, user:, host_selection:, forced_admission_mode:, docker_snapshots_by_host:,
    base_reserved_agent_memory_bytes_by_host:, started_reserved_agent_memory_bytes_by_host:, admission_snapshot:)
    selected_host, admission, decision = resolve_host_admission(
      agent_run: agent_run,
      user: user,
      host_selection: host_selection,
      forced_admission_mode: forced_admission_mode,
      docker_snapshots_by_host: docker_snapshots_by_host,
      base_reserved_agent_memory_bytes_by_host: base_reserved_agent_memory_bytes_by_host,
      started_reserved_agent_memory_bytes_by_host: started_reserved_agent_memory_bytes_by_host,
      admission_snapshot: admission_snapshot
    )

    finalize_infrastructure_spend!(agent_run: agent_run, user: user, selected_host: selected_host, admission: admission)

    [ selected_host, admission, decision ]
  end

  def resolve_host_admission(agent_run:, user:, host_selection:, forced_admission_mode:, docker_snapshots_by_host:,
    base_reserved_agent_memory_bytes_by_host:, started_reserved_agent_memory_bytes_by_host:, admission_snapshot:)
    return select_first_available_host_admission(
      agent_run: agent_run,
      user: user,
      host_selection: host_selection,
      mode: forced_admission_mode,
      docker_snapshots_by_host: docker_snapshots_by_host,
      base_reserved_agent_memory_bytes_by_host: base_reserved_agent_memory_bytes_by_host,
      started_reserved_agent_memory_bytes_by_host: started_reserved_agent_memory_bytes_by_host,
      admission_snapshot: admission_snapshot
    ) unless capacity_aware_host_selection?(host_selection, forced_admission_mode, user)

    evaluations = build_host_admission_evaluations(
      agent_run: agent_run,
      user: user,
      host_selection: host_selection,
      mode: forced_admission_mode,
      docker_snapshots_by_host: docker_snapshots_by_host,
      base_reserved_agent_memory_bytes_by_host: base_reserved_agent_memory_bytes_by_host,
      started_reserved_agent_memory_bytes_by_host: started_reserved_agent_memory_bytes_by_host,
      admission_snapshot: admission_snapshot
    )

    if evaluations.any? { |evaluation| !capacity_snapshot_usable_for_balancing?(evaluation[:admission]) }
      selected_host, admission, manual_decision = select_first_available_host_admission(
        agent_run: agent_run,
        user: user,
        host_selection: host_selection,
        mode: UserSetting::RUN_CONCURRENCY_MODE_MANUAL,
        docker_snapshots_by_host: docker_snapshots_by_host,
        base_reserved_agent_memory_bytes_by_host: base_reserved_agent_memory_bytes_by_host,
        started_reserved_agent_memory_bytes_by_host: started_reserved_agent_memory_bytes_by_host,
        admission_snapshot: admission_snapshot
      )
      return [
        selected_host,
        admission,
        manual_decision.merge(
          decision_mode: "capacity_aware_fallback",
          fallback_reason: "snapshot_unavailable",
          auto_evaluations: placement_evaluations_payload(evaluations)
        )
      ]
    end

    allowed_evaluations = evaluations.select { |evaluation| evaluation[:admission][:allowed] }
    chosen_evaluation = if allowed_evaluations.any?
      allowed_evaluations.max_by do |evaluation|
        admission = evaluation[:admission]
        [
          admission[:available_memory_bytes].to_i,
          admission[:host_available_slots].to_i,
          evaluation[:candidate_host].to_s == host_selection.requested_host.to_s ? 1 : 0,
          -evaluation[:index]
        ]
      end
    else
      evaluations.max_by do |evaluation|
        admission = evaluation[:admission]
        [
          admission[:available_memory_bytes].to_i,
          admission[:host_available_slots].to_i,
          evaluation[:candidate_host].to_s == host_selection.requested_host.to_s ? 1 : 0,
          -evaluation[:index]
        ]
      end
    end

    admission = chosen_evaluation.fetch(:admission)
    [
      chosen_evaluation.fetch(:candidate_host),
      admission,
      {
        decision_mode: "capacity_aware",
        requested_host: host_selection.requested_host,
        selected_host: chosen_evaluation.fetch(:candidate_host),
        selected_by_capacity: true,
        auto_evaluations: placement_evaluations_payload(evaluations),
        selected_snapshot_backend_identifier: admission[:snapshot_backend_identifier],
        selected_snapshot_at: admission[:snapshot_at],
        selected_available_memory_bytes: admission[:available_memory_bytes],
        selected_host_available_slots: admission[:host_available_slots]
      }
    ]
  end

  def select_first_available_host_admission(agent_run:, user:, host_selection:, mode:, docker_snapshots_by_host:,
    base_reserved_agent_memory_bytes_by_host:, started_reserved_agent_memory_bytes_by_host:, admission_snapshot:)
    evaluations = build_host_admission_evaluations(
      agent_run: agent_run,
      user: user,
      host_selection: host_selection,
      mode: mode,
      docker_snapshots_by_host: docker_snapshots_by_host,
      base_reserved_agent_memory_bytes_by_host: base_reserved_agent_memory_bytes_by_host,
      started_reserved_agent_memory_bytes_by_host: started_reserved_agent_memory_bytes_by_host,
      admission_snapshot: admission_snapshot
    )

    chosen_evaluation = nil
    evaluations.each do |evaluation|
      chosen_evaluation = evaluation
      break if evaluation[:admission][:allowed]
      break unless evaluation[:admission][:reason] == "host_hard_ceiling" && host_selection.fallback_enabled?
    end
    chosen_evaluation ||= evaluations.first

    [
      chosen_evaluation[:candidate_host],
      chosen_evaluation[:admission],
      {
        decision_mode: mode == UserSetting::RUN_CONCURRENCY_MODE_MANUAL ? "manual" : "first_healthy",
        requested_host: host_selection.requested_host,
        selected_host: chosen_evaluation[:candidate_host],
        selected_by_capacity: false,
        auto_evaluations: placement_evaluations_payload(evaluations)
      }
    ]
  end

  def build_host_admission_evaluations(agent_run:, user:, host_selection:, mode:, docker_snapshots_by_host:,
    base_reserved_agent_memory_bytes_by_host:, started_reserved_agent_memory_bytes_by_host:, admission_snapshot:)
    host_selection.candidate_hosts.each_with_index.map do |candidate_host, index|
      admission_uses_auto = mode != UserSetting::RUN_CONCURRENCY_MODE_MANUAL && user.settings.run_concurrency_auto?
      docker_snapshot = docker_snapshot_for_host(candidate_host, docker_snapshots_by_host) if admission_uses_auto
      admission = run_admission_for(
        agent_run,
        user,
        mode: mode,
        docker_snapshot: docker_snapshot,
        reserved_agent_memory_bytes: queue_reserved_agent_memory_bytes(
          user,
          base_reserved_agent_memory_bytes_by_host,
          started_reserved_agent_memory_bytes_by_host,
          mode: mode,
          selected_host: candidate_host
        ),
        selected_host: candidate_host,
        selected_host_limit: Containers.host_registry.host_limit_for(candidate_host),
        admission_snapshot: admission_snapshot
      )

      {
        candidate_host: candidate_host,
        index: index,
        admission: admission
      }
    end
  end

  # resolve_host_admission previews the spend guard once per *candidate* host
  # (see #run_admission_for) so an expensive speculative host never publishes
  # notifications, writes audit events, or flips the global emergency control
  # before a cheaper candidate is chosen instead — otherwise those side
  # effects could fire for a host that is never actually used (see review on
  # #3416 / #3581). Once the winning host is known, re-run the real spend
  # guard here so a genuine breach against the *selected* host is still
  # recorded, exactly once per admission decision.
  #
  # Spend accrues monotonically within a single queue pass, so this real
  # check can only confirm — never overturn — a preview denial reached
  # moments earlier; it is skipped entirely when the preview never reached
  # the spend guard (i.e. some other capacity ceiling already denied first).
  def finalize_infrastructure_spend!(agent_run:, user:, selected_host:, admission:)
    return unless selected_host
    return unless spend_guard_reached?(admission)

    result = Capacity::InfrastructureSpendGuard.call(
      account: user.account,
      project: agent_run.project,
      agent_run: agent_run,
      selected_host: selected_host
    )
    return if result[:allowed]

    admission[:allowed] = false
    admission[:reason] = result[:reason]
    admission[:available_slots] = 0
    admission[:rate_limited_until] = result[:rate_limited_until]
    admission.merge!(result.except(:allowed, :reason, :rate_limited_until))
  end

  def spend_guard_reached?(admission)
    admission[:allowed] || spend_capacity_denial?(admission[:reason])
  end

  def spend_capacity_denial?(reason)
    reason.to_s.match?(SPEND_DENIAL_REASON_PATTERN)
  end

  def block_scope_for_spend_denial(reason, project_id:, account_id:, blocked_project_ids:, blocked_account_ids:)
    case reason.to_s
    when /\Aglobal_/
      nil
    when /\Aaccount_/
      blocked_account_ids.add(account_id)
    when /\Aproject_/
      blocked_project_ids.add(project_id)
    end
  end

  def capacity_aware_host_selection?(host_selection, forced_admission_mode, user)
    host_selection.capacity_aware? &&
      !host_selection.explicit? &&
      forced_admission_mode != UserSetting::RUN_CONCURRENCY_MODE_MANUAL &&
      user.settings.run_concurrency_auto?
  end

  def capacity_snapshot_usable_for_balancing?(admission)
    admission[:snapshot_available] && admission[:snapshot_at].present? &&
      Array(admission[:docker_degraded_reasons]).exclude?("stale_cache")
  end

  def placement_evaluations_payload(evaluations)
    evaluations.map do |evaluation|
      admission = evaluation.fetch(:admission)
      {
        host: evaluation.fetch(:candidate_host),
        allowed: admission[:allowed],
        reason: admission[:reason],
        available_memory_bytes: admission[:available_memory_bytes],
        host_available_slots: admission[:host_available_slots],
        snapshot_available: admission[:snapshot_available],
        snapshot_backend_identifier: admission[:snapshot_backend_identifier],
        snapshot_at: admission[:snapshot_at],
        docker_reason: admission[:docker_reason],
        docker_degraded_reasons: admission[:docker_degraded_reasons]
      }.compact
    end
  end

  def docker_snapshot_for_host(candidate_host, docker_snapshots_by_host)
    docker_snapshots_by_host[candidate_host] ||= Capacity::DockerSnapshot.fetch(
      backend: Containers.backend_for(candidate_host)
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

  def queue_reserved_agent_memory_bytes(user, base_reserved_agent_memory_bytes_by_host, started_reserved_agent_memory_bytes_by_host, mode:, selected_host:)
    effective_mode = mode || user.settings.run_concurrency_mode
    return unless effective_mode == UserSetting::RUN_CONCURRENCY_MODE_AUTO
    base_reserved = base_reserved_agent_memory_bytes_by_host[selected_host]
    started_reserved = started_reserved_agent_memory_bytes_by_host[selected_host].to_i
    return if base_reserved.nil? && started_reserved.zero?

    base_reserved.to_i + started_reserved
  end

  def log_capacity_skip(agent_run, admission, host_selection:, host_placement_decision:)
    Rails.logger.info(
      message: "process_run_queue.capacity_denied",
      agent_run_id: agent_run.id,
      project_id: agent_run.project_id,
      goal: agent_run.goal,
      requested_host: host_selection.requested_host,
      selected_host: admission[:selected_host],
      host_active_count: admission[:host_active_count],
      host_max_concurrent_runs: admission[:host_max_concurrent_runs],
      host_available_slots: admission[:host_available_slots],
      selection_source: host_selection.selection_source,
      fallback_policy: host_selection.fallback_policy,
      candidate_hosts: host_selection.candidate_hosts,
      fallback_chain: host_selection_fallback_chain(host_selection),
      reason: admission[:reason],
      mode: admission[:mode],
      available_slots: admission[:available_slots],
      global_active_count: admission[:global_active_count],
      global_max_concurrent_executions: admission[:global_max_concurrent_executions],
      global_available_slots: admission[:global_available_slots],
      effective_max_concurrent_runs: admission[:effective_max_concurrent_runs],
      available_memory_bytes: admission[:available_memory_bytes],
      estimated_memory_per_run_bytes: admission[:estimated_memory_per_run_bytes],
      reserved_agent_memory_bytes: admission[:reserved_agent_memory_bytes],
      requested_cpu_quota: admission[:requested_cpu_quota],
      requested_memory_bytes: admission[:requested_memory_bytes],
      requested_disk_bytes: admission[:requested_disk_bytes],
      current_global_requested_cpu_quota: admission[:current_global_requested_cpu_quota],
      current_global_requested_memory_bytes: admission[:current_global_requested_memory_bytes],
      current_global_requested_disk_bytes: admission[:current_global_requested_disk_bytes],
      global_requested_cpu_quota_limit: admission[:global_requested_cpu_quota_limit],
      global_requested_memory_bytes_limit: admission[:global_requested_memory_bytes_limit],
      global_requested_disk_bytes_limit: admission[:global_requested_disk_bytes_limit],
      current_host_requested_cpu_quota: admission[:current_host_requested_cpu_quota],
      current_host_requested_memory_bytes: admission[:current_host_requested_memory_bytes],
      current_host_requested_disk_bytes: admission[:current_host_requested_disk_bytes],
      host_requested_cpu_quota_limit: admission[:host_requested_cpu_quota_limit],
      host_requested_memory_bytes_limit: admission[:host_requested_memory_bytes_limit],
      host_requested_disk_bytes_limit: admission[:host_requested_disk_bytes_limit],
      current_global_provisionings_per_window: admission[:current_global_provisionings_per_window],
      current_account_provisionings_per_window: admission[:current_account_provisionings_per_window],
      current_project_provisionings_per_window: admission[:current_project_provisionings_per_window],
      global_provisionings_per_window_limit: admission[:global_provisionings_per_window_limit],
      account_provisionings_per_window_limit: admission[:account_provisionings_per_window_limit],
      project_provisionings_per_window_limit: admission[:project_provisionings_per_window_limit],
      rate_limited_until: admission[:rate_limited_until]&.iso8601,
      snapshot_backend_identifier: admission[:snapshot_backend_identifier],
      docker_degraded_reasons: admission[:docker_degraded_reasons],
      docker_reason: admission[:docker_reason],
      degraded: admission[:degraded] == true,
      placement_decision_mode: host_placement_decision[:decision_mode],
      placement_selected_by_capacity: host_placement_decision[:selected_by_capacity] == true
    )
  end

  def log_host_selection_skip(agent_run, host_selection)
    Rails.logger.info(
      message: "process_run_queue.host_unavailable",
      agent_run_id: agent_run.id,
      project_id: agent_run.project_id,
      requested_host: host_selection.requested_host,
      selection_source: host_selection.selection_source,
      fallback_policy: host_selection.fallback_policy,
      fallback_chain: host_selection_fallback_chain(host_selection),
      compatibility_failures: host_selection.compatibility_failures,
      health_failures: host_selection.health_failures
    )
  end

  def log_host_selection(agent_run, host_selection, selected_host, admission, host_placement_decision:)
    Rails.logger.info(
      message: "process_run_queue.host_selected",
      agent_run_id: agent_run.id,
      project_id: agent_run.project_id,
      goal: agent_run.goal,
      requested_host: host_selection.requested_host,
      selected_host: selected_host,
      selection_source: host_selection.selection_source,
      selection_reason: host_selection_reason(host_selection, selected_host, host_placement_decision: host_placement_decision),
      fallback_policy: host_selection.fallback_policy,
      fallback_chain: host_selection_fallback_chain(host_selection),
      candidate_hosts: host_selection.candidate_hosts,
      compatibility_failures: host_selection.compatibility_failures,
      health_failures: host_selection.health_failures,
      host_active_count: admission[:host_active_count],
      host_max_concurrent_runs: admission[:host_max_concurrent_runs],
      host_available_slots: admission[:host_available_slots],
      placement_decision_mode: host_placement_decision[:decision_mode],
      placement_selected_by_capacity: host_placement_decision[:selected_by_capacity] == true,
      selected_available_memory_bytes: admission[:available_memory_bytes],
      snapshot_backend_identifier: admission[:snapshot_backend_identifier]
    )
  end

  def host_selection_reason(host_selection, selected_host, host_placement_decision:)
    return "capacity_fallback" if host_placement_decision[:decision_mode] == "capacity_aware_fallback"
    return "capacity_aware" if host_placement_decision[:selected_by_capacity]
    return "fallback" if selected_host.to_s != host_selection.requested_host.to_s

    host_selection.selection_source
  end

  def host_selection_fallback_chain(host_selection)
    [
      host_selection.requested_host,
      *host_selection.candidate_hosts,
      *host_selection.compatibility_failures.keys,
      *host_selection.health_failures.keys
    ].compact_blank.uniq
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

  def start_claimed_run(agent_run, planned_container_host: nil, host_placement_decision: nil)
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
    workflow_input[:container_host] = planned_container_host if planned_container_host.present?
    plan_docs = agent_run.external_metadata["plan_docs"]
    workflow_input[:plan_docs] = plan_docs if plan_docs.present?

    workflow_id = "queued-#{agent_run.project_id}-#{agent_run.id}-#{Time.current.to_i}"

    # RDR-048 (#2947): record the host this run was admitted against and clear
    # any default container_host so AgentRun.active_count_for_host attributes
    # this claimed run to the correct per-host ceiling before a backend creates
    # or claims a real resource. The container_host column is restored only by
    # a real provision/pool result (see AgentRun#provision_new_container); the
    # planned host in external_metadata is the source of truth for capacity
    # accounting until then. Without this, a run admitted for a remote host
    # would be charged to the local bucket (via its blank container_host) and
    # not to the remote host, allowing the queue to over-admit remotes while
    # starving the local host in a single pass.
    # @spec TEMPORAL-ORCHESTRATION-005 — admission flips the run to running so
    # provisioning/setup/preflight counts as active execution for visibility
    # and capacity accounting. Keep started_at tied to actual agent execution
    # in RunAgentActivity so max_execution_seconds and stale-running thresholds
    # do not start burning down during Temporal admission/provisioning.
    update_attributes = {
      temporal_workflow_id: workflow_id,
      status: "running",
      completed_at: nil,
      external_metadata: agent_run.external_metadata
    }
    if planned_container_host.present?
      update_attributes[:container_host] = nil
      update_attributes[:external_metadata] = update_attributes[:external_metadata].merge({
        "planned_container_host" => planned_container_host
      }).tap do |metadata|
        metadata["host_placement_decision"] = serialize_host_placement_decision(host_placement_decision) if host_placement_decision.present?
      end
    end

    # Write the planned workflow_id before starting the workflow so
    # StaleRunDetectorJob can cancel an orphaned workflow even if the
    # process crashes between start_workflow and the DB write.
    # Queue admission is an infrastructure transition, so skip unrelated
    # validations that may have drifted since the run was created while
    # still saving normally to fire after_commit broadcasts/followups.
    agent_run.assign_attributes(**update_attributes)
    agent_run.save!(validate: false)

    # Keep temporal_workflow_id set on failure — if start_workflow raises
    # due to a network timeout, the workflow may have started server-side.
    # Leaving the ID allows StaleRunDetectorJob to find and cancel the
    # potentially-orphaned workflow rather than losing track of it.
    workflow_handle = start_workflow!(
      agent_run,
      workflow_input: workflow_input,
      workflow_id: workflow_id
    )
    return false unless workflow_handle

    return false unless record_provisioning_start_after_start(
      agent_run,
      workflow_id: workflow_id,
      workflow_handle: workflow_handle,
      planned_container_host: planned_container_host
    )

    ExecutionAuditEvents::Lifecycle.record(
      event_name: "execution.admitted",
      actor_id: "process_run_queue",
      agent_run: agent_run,
      backend: planned_container_host,
      correlation_id: workflow_id,
      metadata: {
        selected_host: planned_container_host
      }
    )

    Rails.logger.info(
      message: "process_run_queue.started_queued_run",
      agent_run_id: agent_run.id,
      workflow_id: workflow_id
    )
    true
  end

  # @spec OBSERVABILITY-002 — record provisioning_started_at and
  # requested_resources only after Temporal accepted the workflow start so
  # failed dispatch attempts do not create phantom infrastructure spend.
  def record_provisioning_start!(agent_run, planned_container_host)
    started_at = Time.current
    metadata = agent_run.external_metadata.merge(
      "provisioning_started_at" => started_at.iso8601,
      "requested_resources" => Capacity::RequestedResources.persistable_for(agent_run),
      "infrastructure_spend" => {
        "rate_cents_per_hour" => Capacity::InfrastructureLimits.rate_cents_per_hour(host: planned_container_host),
        "projection_seconds" => Capacity::InfrastructureLimits.current(host: planned_container_host)[:infra_spend_projection_seconds]
      }
    )

    agent_run.update_columns(
      provisioning_started_at: started_at,
      external_metadata: metadata,
      updated_at: Time.current
    )
  end

  def start_workflow!(agent_run, workflow_input:, workflow_id:)
    Paid.temporal_client.start_workflow(
      Workflows::AgentExecutionWorkflow,
      workflow_input,
      id: workflow_id,
      task_queue: Paid.agent_task_queue,
      priority: temporal_priority_for(agent_run)
    )
  rescue => e
    keep_run_claimed_for_cleanup(agent_run, error: "Failed to start workflow: #{e.message}")
    Rails.logger.error(
      message: "process_run_queue.start_failed",
      agent_run_id: agent_run.id,
      workflow_id: workflow_id,
      error: e.message
    )
    false
  end

  def record_provisioning_start_after_start(agent_run, workflow_id:, workflow_handle:, planned_container_host:)
    record_provisioning_start!(agent_run, planned_container_host)
  rescue => e
    error = "Failed to persist provisioning metadata after workflow start: #{e.message}"
    cancellation_outcome = cancel_started_workflow(workflow_handle, agent_run, workflow_id)
    if cancellation_outcome == :confirmed
      force_fail_run(agent_run, error: error)
    else
      keep_run_claimed_for_cleanup(agent_run, error: error)
    end
    Rails.logger.error(
      message: "process_run_queue.provisioning_metadata_persist_failed",
      agent_run_id: agent_run.id,
      workflow_id: workflow_id,
      error: e.message,
      cleanup_pending: cancellation_outcome != :confirmed
    )
    false
  end

  def cancel_started_workflow(workflow_handle, agent_run, workflow_id)
    workflow_handle.cancel
    :confirmed
  rescue Temporalio::Error::RPCError => e
    raise unless e.code == Temporalio::Error::RPCError::Code::NOT_FOUND

    Rails.logger.info(
      message: "process_run_queue.provisioning_metadata_cancel_not_found",
      agent_run_id: agent_run.id,
      workflow_id: workflow_id
    )
    :pending_cleanup
  rescue => e
    Rails.logger.warn(
      message: "process_run_queue.provisioning_metadata_cancel_failed",
      agent_run_id: agent_run.id,
      workflow_id: workflow_id,
      error_class: e.class.name,
      error: e.message
    )
    :pending_cleanup
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

  # When workflow start or immediate post-start cleanup cannot be confirmed,
  # keep the run in claimed-queued state so StaleRunDetectorJob retries the
  # cancellation before this run can be started again.
  def keep_run_claimed_for_cleanup(agent_run, error:)
    agent_run.assign_attributes(
      status: "queued",
      completed_at: nil,
      error_message: error,
      duration_seconds: nil
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

  def serialize_host_placement_decision(decision)
    decision.deep_dup.tap do |payload|
      payload["requested_host"] = payload.delete(:requested_host) if payload.key?(:requested_host)
      payload["selected_host"] = payload.delete(:selected_host) if payload.key?(:selected_host)
      payload["decision_mode"] = payload.delete(:decision_mode) if payload.key?(:decision_mode)
      payload["selected_by_capacity"] = payload.delete(:selected_by_capacity) if payload.key?(:selected_by_capacity)
      payload["fallback_reason"] = payload.delete(:fallback_reason) if payload.key?(:fallback_reason)
      payload["auto_evaluations"] = payload.delete(:auto_evaluations) if payload.key?(:auto_evaluations)
      payload["selected_snapshot_backend_identifier"] = payload.delete(:selected_snapshot_backend_identifier) if payload.key?(:selected_snapshot_backend_identifier)
      payload["selected_snapshot_at"] = payload.delete(:selected_snapshot_at)&.iso8601 if payload.key?(:selected_snapshot_at)
      payload["selected_available_memory_bytes"] = payload.delete(:selected_available_memory_bytes) if payload.key?(:selected_available_memory_bytes)
      payload["selected_host_available_slots"] = payload.delete(:selected_host_available_slots) if payload.key?(:selected_host_available_slots)
    end
  end

  def temporal_priority_for(agent_run)
    Temporalio::Priority.new(
      priority_key: TEMPORAL_PRIORITY_KEYS.fetch(agent_run.queue_priority_tier),
      fairness_key: temporal_fairness_key_for(agent_run)
    )
  end

  def next_queued_run_for_scheduler(skipped_ids:, blocked_project_ids:, blocked_user_ids:, blocked_account_ids:,
    blocked_account_create_pr_ids:, blocked_account_dispatch_ids:)
    ranked_scope = schedulable_queue_scope(
      skipped_ids: skipped_ids,
      blocked_project_ids: blocked_project_ids,
      blocked_user_ids: blocked_user_ids,
      blocked_account_ids: blocked_account_ids,
      blocked_account_create_pr_ids: blocked_account_create_pr_ids,
      blocked_account_dispatch_ids: blocked_account_dispatch_ids
    ).select("#{account_scheduler_rank_sql} AS account_queue_rank")

    AgentRun.from("(#{ranked_scope.to_sql}) agent_runs")
      .where(account_queue_rank: 1)
      .order(*cross_account_scheduler_order)
      .first
  end

  # Each account first picks its own queue head using its configured mode.
  # Cross-account competition stays mode-neutral, so one tenant enabling
  # strict priority cannot globally reorder another tenant's work.
  def account_scheduler_rank_sql
    <<~SQL.squish
      ROW_NUMBER() OVER (
        PARTITION BY projects.account_id
        ORDER BY
          CASE
            WHEN #{queue_fairness_mode_sql} = 'fair_share'
            THEN COALESCE(project_active_counts.project_active_count, 0)
          END ASC NULLS LAST,
          CASE
            WHEN #{queue_fairness_mode_sql} = 'fair_share'
            THEN COALESCE(user_active_counts.user_active_count, 0)
          END ASC NULLS LAST,
          #{AgentRun::QUEUE_PRIORITY_CASE_SQL} ASC,
          #{AgentRun::IN_PROGRESS_CASE_SQL} ASC,
          #{AgentRun::GOAL_PRIORITY_CASE_SQL} ASC,
          #{AgentRun::REVIEW_PICKUP_PRIORITY_CASE_SQL} ASC,
          agent_runs.created_at ASC,
          agent_runs.id ASC
      )
    SQL
  end

  def schedulable_queue_scope(skipped_ids:, blocked_project_ids:, blocked_user_ids:, blocked_account_ids:,
    blocked_account_create_pr_ids:, blocked_account_dispatch_ids:)
    scope = AgentRun.unclaimed_with_priority
      .joins(project: :account)
      .joins("LEFT JOIN tenant_settings ON tenant_settings.account_id = projects.account_id")
      .where(accounts: { scheduler_paused_at: nil })
      .where(projects: { scheduler_paused_at: nil })
      .where("agent_runs.trigger_type = 'manual' OR projects.quality_paused_at IS NULL")
      .where("agent_runs.trigger_type = 'manual' OR projects.paused = FALSE")
    scope = scope.where.not(id: skipped_ids.to_a) if skipped_ids.any?
    scope = scope.where.not(project_id: blocked_project_ids.to_a) if blocked_project_ids.any?
    scope = scope.where("project_owner.user_id NOT IN (?)", blocked_user_ids.to_a) if blocked_user_ids.any?
    scope = scope.where.not(projects: { account_id: blocked_account_ids.to_a }) if blocked_account_ids.any?
    scope = scope.where.not(projects: { account_id: blocked_account_dispatch_ids.to_a }) if blocked_account_dispatch_ids.any?
    if blocked_account_create_pr_ids.any?
      scope = scope.where(
        "agent_runs.goal != 'create_pr' OR projects.account_id NOT IN (?)",
        blocked_account_create_pr_ids.to_a
      )
    end
    scope
  end

  def queue_fairness_mode_sql
    "COALESCE(tenant_settings.queue_fairness_mode, '#{TenantSetting::DEFAULT_QUEUE_FAIRNESS_MODE}')"
  end

  def cross_account_scheduler_order
    [
      Arel.sql("agent_runs.project_active_count ASC"),
      Arel.sql("agent_runs.user_active_count ASC"),
      Arel.sql("agent_runs.queue_priority ASC"),
      Arel.sql("CASE WHEN agent_runs.source_pull_request_number IS NOT NULL THEN 0 ELSE 1 END ASC"),
      Arel.sql("agent_runs.goal_priority ASC"),
      Arel.sql("CASE WHEN agent_runs.goal = 'review' THEN 0 ELSE 1 END ASC"),
      { created_at: :asc, id: :asc }
    ]
  end

  def temporal_fairness_key_for(agent_run)
    agent_run.project.account_id.to_s
  end
end
