# frozen_string_literal: true

module Activities
  class QueueAgentRunActivity < BaseActivity
    activity_name "QueueAgentRun"

    def execute(input)
      project_id = input[:project_id]
      issue_id = input[:issue_id]
      custom_prompt = input[:custom_prompt]
      requested_agent_type = input[:agent_type]
      provider_id = input[:runner_id]
      source_pull_request_number = input[:source_pull_request_number]
      goal = input[:goal]
      focus = input[:focus] || "general"
      count_toward_draft_review_round = input.fetch(:count_toward_draft_review_round, false)
      expected_draft_review_count = input[:expected_draft_review_count]

      project = Project.find(project_id)
      goal ||= project.account.tenant_setting&.default_goal || "create_pr"
      issue = issue_id ? Issue.find(issue_id) : nil
      respect_requested = input.key?(:agent_type) || input.key?(:runner_id)
      provider_id, agent_type = resolve_runner_selection(
        project: project,
        requested_agent_type: requested_agent_type,
        requested_runner_id: provider_id,
        goal: goal,
        agent_type_provided: input.key?(:agent_type),
        runner_id_provided: input.key?(:runner_id)
      )

      # Use a transaction with row-level locking to prevent duplicate
      # queued/active runs for the same issue or PR under concurrency.
      # Falls back to DB unique indexes (RecordNotUnique) as a safety net
      # for races between concurrent activity executions.
      agent_run, duplicate = AgentRun.transaction do
        existing = find_existing_run(project, issue, source_pull_request_number)
        if existing
          if existing.goal == goal
            merge_draft_review_round_tracking!(existing,
              count_toward_draft_review_round: count_toward_draft_review_round,
              expected_draft_review_count: expected_draft_review_count)
          end
          [ existing, true ]
        else
          run = AgentRun.create!(
            project: project,
            issue: issue,
            initiating_user_id: input[:initiating_user_id],
            provider_id: provider_id,
            agent_type: agent_type,
            custom_prompt: custom_prompt,
            source_pull_request_number: source_pull_request_number,
            goal: goal,
            focus: focus,
            count_toward_draft_review_round: count_toward_draft_review_round,
            expected_draft_review_count: expected_draft_review_count,
            status: "queued"
          )
          [ run, false ]
        end
      rescue ActiveRecord::RecordNotUnique
        existing = find_existing_run(project, issue, source_pull_request_number)
        raise unless existing

        # Runs outside the rolled-back transaction without a row lock. If two
        # concurrent RecordNotUnique rescues race here, the idempotency guard in
        # merge_draft_review_round_tracking! prevents double-writes. Both callers
        # originate from the same poll cycle so they pass identical values; the
        # last writer wins harmlessly.
        if existing.goal == goal
          merge_draft_review_round_tracking!(existing,
            count_toward_draft_review_round: count_toward_draft_review_round,
            expected_draft_review_count: expected_draft_review_count)
        end

        [ existing, true ]
      end

      if duplicate
        logger.info(
          message: "concurrency.duplicate_run_skipped",
          agent_run_id: agent_run.id,
          project_id: project_id,
          issue_id: issue_id,
          requested_goal: goal,
          existing_goal: agent_run.goal,
          cross_goal: agent_run.goal != goal
        )
        return { agent_run_id: agent_run.id, queued: false, duplicate: true,
                 cross_goal: agent_run.goal != goal }
      end

      AgentRuns::RunnerSelectionLogger.call(
        project: project,
        issue: issue,
        agent_run: agent_run,
        goal: goal,
        requested_agent_type: requested_agent_type,
        requested_runner_id: input[:runner_id],
        respect_requested: respect_requested,
        resolved_runner_id: provider_id,
        resolved_agent_type: agent_type
      )

      logger.info(
        message: "concurrency.agent_run_queued",
        agent_run_id: agent_run.id,
        project_id: project_id,
        issue_id: issue_id
      )

      ProcessRunQueueJob.perform_later

      { agent_run_id: agent_run.id, queued: true }
    end

    private

    def resolve_runner_selection(project:, requested_agent_type:, requested_runner_id:, goal:, agent_type_provided:, runner_id_provided:)
      AgentRuns::RunnerResolver.call(
        project: project,
        goal: goal,
        requested_agent_type: requested_agent_type,
        requested_runner_id: requested_runner_id,
        respect_requested: runner_id_provided || agent_type_provided,
        logger: logger
      )
    end

    # Returns nil for custom-prompt-only runs (no issue or PR) intentionally:
    # custom prompts are unique by definition and cannot be meaningfully deduplicated.
    #
    # Deduplication is goal-agnostic: any unfinished run for the same issue or
    # source PR blocks queueing another. Two runs against the same PR share a
    # branch and worktree (e.g. a review and a create_pr both cloned to
    # /workspace), so allowing them to run concurrently caused WorktreeConflict
    # failures whenever the poll cycle fired both at once. The poller will
    # re-evaluate next cycle once the in-flight run finishes.
    def find_existing_run(project, issue, source_pull_request_number)
      scope = project.agent_runs.where(status: AgentRun::UNFINISHED_STATUSES).lock("FOR UPDATE")
      if issue
        scope.where(issue: issue).first
      elsif source_pull_request_number
        scope.where(source_pull_request_number: source_pull_request_number).first
      end
    end

    def merge_draft_review_round_tracking!(agent_run, count_toward_draft_review_round:, expected_draft_review_count:)
      return unless count_toward_draft_review_round
      return if agent_run.count_toward_draft_review_round? &&
        agent_run.expected_draft_review_count.present?

      if agent_run.trigger_type != "automatic"
        logger.warn(
          message: "concurrency.draft_tracking_skipped_manual_run",
          agent_run_id: agent_run.id
        )
        return
      end

      agent_run.update!(
        count_toward_draft_review_round: true,
        expected_draft_review_count: expected_draft_review_count
      )
    end
  end
end
