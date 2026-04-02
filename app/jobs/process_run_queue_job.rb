# frozen_string_literal: true

require "digest/md5"
require "set"

class ProcessRunQueueJob < ApplicationJob
  queue_as :default

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
  MAX_SEEDS_PER_PERFORM = 20
  AUTO_PICK_RESERVED_SLOTS = 1

  def perform
    # Use a PostgreSQL advisory lock to ensure only one job processes the queue at a time.
    # If another instance is already running, this job exits immediately (no-op).
    acquired = ActiveRecord::Base.connection.select_value("SELECT pg_try_advisory_lock(#{ADVISORY_LOCK_KEY})")
    return unless acquired

    begin
      consecutive_failures = 0
      starts_count = 0
      iterations = 0
      skipped_ids = Set.new
      @user_capacity = {}  # { user_id => { active: count, max: limit } }

      seed_auto_pick_queue

      loop do
        iterations += 1
        break if iterations > MAX_ITERATIONS_PER_PERFORM
        # Peek at the next queued run without claiming it, so we can check
        # per-user capacity before transitioning to "pending". This avoids
        # an unnecessary queued -> pending -> queued status flip (and its
        # associated broadcasts/metrics) for runs that can't start yet.
        next_run = AgentRun.peek_next_queued_run(exclude_ids: skipped_ids.to_a)

        break unless next_run

        # Resolve the project owner for capacity checks. If the owner
        # can't be resolved, fail the run immediately rather than
        # skipping it — a nil owner would block auto-pick for other
        # users who may have capacity.
        user = next_run.project.effective_owner
        unless user
          if (run = AgentRun.claim_next_queued_run(target_id: next_run.id))
            run.fail!(error: "Cannot resolve project owner for capacity check")
          end
          next
        end

        unless user_has_capacity?(user, next_run)
          skipped_ids.add(next_run.id)
          next
        end

        # User has capacity — now atomically claim the run.
        # claim_next_queued_run returns nil if another process claimed or
        # transitioned this run between peek and claim. Skip it and continue
        # processing the queue rather than stopping entirely.
        agent_run = AgentRun.claim_next_queued_run(target_id: next_run.id)
        unless agent_run
          skipped_ids.add(next_run.id)
          next
        end

        if start_claimed_run(agent_run)
          consecutive_failures = 0
          starts_count += 1
          record_started_run(user)
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

  # Checks per-user capacity using an in-memory cache. The active count
  # is fetched from the DB on first access per user, then updated
  # in-memory as runs are started, avoiding repeated COUNT queries.
  def user_has_capacity?(user, run)
    cap = @user_capacity[user.id] ||= {
      active: AgentRun.active_count_for_user(user),
      max: user.settings.max_concurrent_runs
    }
    cap[:active] < start_capacity_limit(cap[:max], run)
  end

  # Updates the in-memory capacity tracker after a run is started.
  def record_started_run(user)
    cap = @user_capacity[user.id]
    cap[:active] += 1 if cap
  end

  # Seeds the queue with all currently auto-pickable issues before run
  # selection. Priorities still determine what starts next, but keeping
  # low-priority auto-pick work queued makes latent work visible and ready
  # to consume spare capacity.
  def seed_auto_pick_queue
    seeds_count = 0

    loop do
      break if seeds_count >= MAX_SEEDS_PER_PERFORM

      created_in_pass = false

      ordered_auto_pick_projects.each do |project|
        break if seeds_count >= MAX_SEEDS_PER_PERFORM

        next unless project.effective_owner

        run = Issues::AutoPick.new(project).call
        next unless run

        seeds_count += 1
        created_in_pass = true
        @ordered_auto_pick_projects = nil
      end

      break unless created_in_pass
    end
  end

  # Memoized within a single perform so repeated auto-pick passes
  # don't re-query the project list and aggregate stats each time.
  def ordered_auto_pick_projects
    @ordered_auto_pick_projects ||= begin
      projects = Project.active.where(auto_pick_enabled: true).includes(:created_by, :account).order(:id).to_a
      return projects if projects.empty?

      project_ids = projects.map(&:id)
      auto_pick_scope = AgentRun.where(
        project_id: project_ids,
        trigger_type: "automatic",
        source_pull_request_number: nil
      ).where.not(issue_id: nil)

      active_counts = auto_pick_scope.where(
        status: AgentRun::UNFINISHED_STATUSES
      ).group(:project_id).count

      # Collapse the two aggregate queries (max created_at, max id)
      # into a single grouped pluck to reduce DB round-trips.
      last_stats = {}
      auto_pick_scope
        .group(:project_id)
        .pluck(:project_id, Arel.sql("MAX(created_at)"), Arel.sql("MAX(id)"))
        .each do |project_id, max_created_at, max_id|
          last_stats[project_id] = { at: max_created_at, id: max_id }
        end

      projects.sort_by do |project|
        stats = last_stats[project.id]
        [
          active_counts.fetch(project.id, 0),
          stats ? stats[:at] : Time.at(0),
          stats ? stats[:id] : 0,
          project.id
        ]
      end
    end
  end

  def start_capacity_limit(max_concurrent_runs, run)
    return max_concurrent_runs unless auto_pick_run?(run)

    reserved = max_concurrent_runs > AUTO_PICK_RESERVED_SLOTS ? AUTO_PICK_RESERVED_SLOTS : 0
    max_concurrent_runs - reserved
  end

  # Treat a run as auto-pick if it is explicitly marked via the auto_pick
  # column, or if it matches the legacy inference used elsewhere in the
  # scheduler (automatic trigger with no source pull request).  The legacy
  # check keeps reserved-slot behavior consistent until all historical
  # rows are backfilled.
  def auto_pick_run?(run)
    run.auto_pick? || (run.trigger_type == "automatic" && run.source_pull_request_number.nil?)
  end

  def start_claimed_run(agent_run)
    budget_result = CostBudgets::Check.call(agent_run.project)
    unless budget_result[:allowed]
      agent_run.fail!(error: "Budget enforcement: #{budget_result[:reason]}")
      Rails.logger.warn(
        message: "process_run_queue.budget_blocked",
        agent_run_id: agent_run.id,
        reason: budget_result[:reason]
      )
      return true # not a workflow failure, don't count as consecutive failure
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
      task_queue: Paid.task_queue
    )

    Rails.logger.info(
      message: "process_run_queue.started_queued_run",
      agent_run_id: agent_run.id,
      workflow_id: workflow_id
    )
    true
  rescue => e
    agent_run.fail!(error: "Failed to start workflow: #{e.message}")
    Rails.logger.error(
      message: "process_run_queue.start_failed",
      agent_run_id: agent_run.id,
      error: e.message
    )
    false
  end
end
