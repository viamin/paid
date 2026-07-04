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
      # run". For pinned runs the corresponding run is also added to
      # +skipped_ids+ so it is not retried; for unbound runs the run
      # stays queued and the resolver will pick a different runner next
      # pass if one is healthy.
      blocked_runner_ids = Set.new
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

        docker_snapshot ||= Capacity::DockerSnapshot.fetch if user.settings.run_concurrency_auto?
        admission = run_admission_for(
          next_run,
          user,
          docker_snapshot: docker_snapshot,
          reserved_agent_memory_bytes: queue_reserved_agent_memory_bytes(
            user,
            base_reserved_agent_memory_bytes,
            started_reserved_agent_memory_bytes
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

        # Late-bind a runner for runner-agnostic queued runs (#2563).
        # The resolver is constrained to runnable runners AND excludes any
        # runner that already failed preflight during this pass
        # (+blocked_runner_ids+), so a healthy alternative is picked when the
        # preferred runner is rate-limited / circuit-open. If no runnable
        # runner can be resolved the run stays queued and we move on to the
        # next peek.
        bound_for_this_iteration = false
        if next_run.runner_unbound?
          bound_runner = AgentRuns::BindRunner.call(agent_run: next_run, exclude_runner_ids: blocked_runner_ids)
          unless bound_runner
            log_no_runnable_runner(next_run)
            next
          end
          bound_for_this_iteration = true
        end

        if next_run.runner_id && blocked_runner_ids.include?(next_run.runner_id)
          if bound_for_this_iteration
            # Defense in depth: a late-bound run should never resolve to a
            # blocked runner (the resolver excludes them), but if it does,
            # clear the pin so the next pass re-resolves rather than
            # stranding the run on it.
            next_run.update_columns(runner_id: nil)
          else
            skipped_ids.add(next_run.id)
          end
          next
        end

        preflight_result = check_runner_preflight(next_run, user)
        if preflight_result && !preflight_result.pass?
          log_preflight_skip(next_run, preflight_result)
          blocked_runner_ids.add(preflight_result.runner_id) if preflight_result.runner_id
          if bound_for_this_iteration
            # Late-bound on this pass: clear the pin so the next pass
            # re-resolves (a different healthy runner may be available
            # by then). The run stays queued; the runner was just
            # unhealthy, not the run.
            next_run.update_columns(runner_id: nil)
          else
            # Pinned (manually assigned) runs are stuck to one
            # runner — keep the run skipped for the rest of this pass
            # and try again next tick.
            skipped_ids.add(next_run.id)
          end
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

  def run_admission_for(agent_run, user, docker_snapshot:, reserved_agent_memory_bytes:)
    Capacity::RunAdmission.call(
      user: user,
      project: agent_run.project,
      goal: agent_run.goal,
      docker_snapshot: docker_snapshot,
      reserved_agent_memory_bytes: reserved_agent_memory_bytes
    )
  end

  def queue_reserved_agent_memory_bytes(user, base_reserved_agent_memory_bytes, started_reserved_agent_memory_bytes)
    return unless user.settings.run_concurrency_auto?
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

  def temporal_priority_for(agent_run)
    Temporalio::Priority.new(
      priority_key: AgentRun::QUEUE_PRIORITIES.fetch(agent_run.queue_priority_tier).fetch(:indicator),
      fairness_key: temporal_fairness_key_for(agent_run)
    )
  end

  def temporal_fairness_key_for(agent_run)
    agent_run.project.account_id.to_s
  end
end
