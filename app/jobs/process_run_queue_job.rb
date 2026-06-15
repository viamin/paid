# frozen_string_literal: true

require "digest/md5"
require "set"

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
      blocked_runner_ids = Set.new
      blocked_account_create_pr_ids = Set.new
      blocked_account_dispatch_ids = Set.new
      started_priority_by_project = {}

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
          exclude_account_create_pr_ids: blocked_account_create_pr_ids.to_a
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

        unless user_has_capacity?(user)
          # Exclude the whole owner for the rest of this pass so a deep
          # backlog for a saturated user cannot consume the iteration budget
          # one queued row at a time.
          blocked_user_ids.add(user.id)
          next
        end

        if next_run.runner_id && blocked_runner_ids.include?(next_run.runner_id)
          skipped_ids.add(next_run.id)
          next
        end

        preflight_result = check_runner_preflight(next_run, user)
        if preflight_result && !preflight_result.pass?
          log_preflight_skip(next_run, preflight_result)
          skipped_ids.add(next_run.id)
          blocked_runner_ids.add(next_run.runner_id) if next_run.runner_id
          next
        end

        if dispatch_halted?(next_run, blocked_account_dispatch_ids)
          next
        end

        if next_run.goal == "create_pr" && !account_has_create_pr_capacity?(next_run.project.account)
          blocked_account_create_pr_ids.add(next_run.project.account_id)
          next
        end

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
          consecutive_failures = 0
          starts_count += 1
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

  def user_has_capacity?(user)
    AgentRun.active_count_for_user(user) < user.account.tenant_max_concurrent_runs(user.settings.max_concurrent_runs)
  end

  def account_has_create_pr_capacity?(account)
    AgentRun.active_create_pr_count_for_account(account) < account.tenant_max_concurrent_create_pr_runs
  end

  def dispatch_halted?(agent_run, blocked_account_dispatch_ids)
    account = agent_run.project.account
    return false if blocked_account_dispatch_ids.include?(account.id)

    service = ::AgentRuns::DispatchCircuitBreaker.new(account)
    decision = service.probe_decision

    case decision
    when :dispatch
      false
    when :allow_probe
      service.mark_probe_dispatched!
      Rails.logger.info(
        message: "process_run_queue.dispatch_probe",
        agent_run_id: agent_run.id,
        account_id: account.id
      )
      false
    else
      blocked_account_dispatch_ids.add(account.id)
      Rails.logger.info(
        message: "process_run_queue.dispatch_halted",
        agent_run_id: agent_run.id,
        account_id: account.id
      )
      true
    end
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
      task_queue: Paid.agent_task_queue
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
end
