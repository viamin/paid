# frozen_string_literal: true

module Activities
  class QueueAgentRunActivity < BaseActivity
    activity_name "QueueAgentRun"

    def execute(input)
      project_id = input[:project_id]
      issue_id = input[:issue_id]
      custom_prompt = input[:custom_prompt]
      requested_agent_type = input[:agent_type]
      provider_id = input[:provider_id]
      source_pull_request_number = input[:source_pull_request_number]
      goal = input[:goal] || "create_pr"
      count_toward_draft_review_round = input.fetch(:count_toward_draft_review_round, false)
      expected_draft_review_count = input[:expected_draft_review_count]

      project = Project.find(project_id)
      issue = issue_id ? Issue.find(issue_id) : nil
      provider_id, agent_type = resolve_provider_selection(
        project: project,
        requested_agent_type: requested_agent_type,
        requested_provider_id: provider_id,
        goal: goal,
        agent_type_provided: input.key?(:agent_type),
        provider_id_provided: input.key?(:provider_id)
      )

      # Use a transaction with row-level locking to prevent duplicate
      # queued/active runs for the same issue or PR under concurrency.
      # Falls back to DB unique indexes (RecordNotUnique) as a safety net
      # for races between concurrent activity executions.
      agent_run, duplicate = AgentRun.transaction do
        existing = find_existing_run(project, issue, source_pull_request_number, goal: goal)
        if existing
          merge_draft_review_round_tracking!(existing,
            count_toward_draft_review_round: count_toward_draft_review_round,
            expected_draft_review_count: expected_draft_review_count)
          [ existing, true ]
        else
          run = AgentRun.create!(
            project: project,
            issue: issue,
            provider_id: provider_id,
            agent_type: agent_type,
            custom_prompt: custom_prompt,
            source_pull_request_number: source_pull_request_number,
            goal: goal,
            count_toward_draft_review_round: count_toward_draft_review_round,
            expected_draft_review_count: expected_draft_review_count,
            status: "queued"
          )
          [ run, false ]
        end
      rescue ActiveRecord::RecordNotUnique
        existing = find_existing_run(project, issue, source_pull_request_number, goal: goal)
        raise unless existing

        # Runs outside the rolled-back transaction without a row lock. If two
        # concurrent RecordNotUnique rescues race here, the idempotency guard in
        # merge_draft_review_round_tracking! prevents double-writes. Both callers
        # originate from the same poll cycle so they pass identical values; the
        # last writer wins harmlessly.
        merge_draft_review_round_tracking!(existing,
          count_toward_draft_review_round: count_toward_draft_review_round,
          expected_draft_review_count: expected_draft_review_count)

        [ existing, true ]
      end

      if duplicate
        logger.info(
          message: "concurrency.duplicate_run_skipped",
          agent_run_id: agent_run.id,
          project_id: project_id,
          issue_id: issue_id
        )
        return { agent_run_id: agent_run.id, queued: false, duplicate: true }
      end

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

    def resolve_provider_selection(project:, requested_agent_type:, requested_provider_id:, goal:, agent_type_provided:, provider_id_provided:)
      if provider_id_provided || agent_type_provided
        provider = provider_for_id(requested_provider_id)
        return [ provider.id, Provider.agent_type_for(provider.provider_key) ] if provider && provider_runnable?(provider)
        return [ nil, requested_agent_type ] if agent_type_runnable?(requested_agent_type)

        logger.warn(
          message: "agent_execution.requested_provider_not_runnable",
          project_id: project.id,
          requested_provider_id: requested_provider_id,
          requested_agent_type: requested_agent_type
        )
      end

      provider = default_provider_for(project, goal: goal)
      return [ provider&.id, Provider.agent_type_for(provider.provider_key) ] if provider

      [ nil, "claude_code" ]
    end

    def provider_runnable?(provider)
      ProviderSupport.container_executable_provider_key?(provider.provider_key)
    end

    def agent_type_runnable?(agent_type)
      return false if agent_type.blank?

      AgentRun::AGENT_TYPES.include?(agent_type) &&
        ProviderSupport.container_executable_provider_key?(Provider.provider_key_for_agent_type(agent_type))
    end

    def default_provider_for(project, goal:)
      owner = project.effective_owner
      return unless owner

      settings = AgentRuns::UserSettingsResolver.call(project: project, strict: false)
      return Provider.ensure_default_for(owner) unless settings

      identifier = settings.select_automated_provider_identifier(goal: goal) ||
        settings.default_provider_identifier_for_goal(goal)
      Provider.for_identifier(settings.user, identifier) || Provider.ensure_default_for(settings.user)
    end

    def provider_for_id(provider_id)
      return if provider_id.blank?

      Provider.find_by(id: provider_id)
    end

    # Returns nil for custom-prompt-only runs (no issue or PR) intentionally:
    # custom prompts are unique by definition and cannot be meaningfully deduplicated.
    # The goal parameter ensures review-goal runs are deduplicated separately
    # from create_pr runs targeting the same PR.
    def find_existing_run(project, issue, source_pull_request_number, goal: "create_pr")
      scope = project.agent_runs.where(status: AgentRun::UNFINISHED_STATUSES, goal: goal).lock("FOR UPDATE")
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
