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
      goal = input[:goal]

      project = Project.find(project_id)
      issue = issue_id ? Issue.find(issue_id) : nil
      provider_id, agent_type = resolve_provider_selection(
        project: project,
        requested_agent_type: requested_agent_type,
        requested_provider_id: provider_id,
        agent_type_provided: input.key?(:agent_type),
        provider_id_provided: input.key?(:provider_id)
      )

      # Use a transaction with row-level locking to prevent duplicate
      # queued/active runs for the same issue or PR under concurrency.
      # Falls back to DB unique indexes (RecordNotUnique) as a safety net
      # for races between concurrent activity executions.
      agent_run, duplicate = AgentRun.transaction do
        existing = find_existing_run(project, issue, source_pull_request_number)
        if existing
          [ existing, true ]
        else
          attrs = {
            project: project,
            issue: issue,
            provider_id: provider_id,
            agent_type: agent_type,
            custom_prompt: custom_prompt,
            source_pull_request_number: source_pull_request_number,
            status: "queued"
          }
          attrs[:goal] = goal if goal.present?
          # NOTE: find_existing_run does not scope by goal, so a review-goal
          # run will be deduplicated against an in-flight create_pr run for
          # the same issue/PR. This is acceptable for now because the poll
          # workflow defers review requests when other triggers are present,
          # but could miss reviews if a prior-cycle followup is still running.
          run = AgentRun.create!(**attrs)
          [ run, false ]
        end
      rescue ActiveRecord::RecordNotUnique
        existing = find_existing_run(project, issue, source_pull_request_number)
        raise unless existing
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

    def resolve_provider_selection(project:, requested_agent_type:, requested_provider_id:, agent_type_provided:, provider_id_provided:)
      if provider_id_provided || agent_type_provided
        provider = provider_for_id(requested_provider_id)
        resolved_agent_type =
          if provider
            Provider.agent_type_for(provider.provider_key)
          else
            requested_agent_type || "claude_code"
          end

        return [ requested_provider_id, resolved_agent_type ]
      end

      provider = default_provider_for(project)
      return [ provider&.id, Provider.agent_type_for(provider.provider_key) ] if provider

      [ nil, "claude_code" ]
    end

    def default_provider_for(project)
      owner = project.effective_owner
      return unless owner

      settings = AgentRuns::UserSettingsResolver.call(project: project, strict: false)
      return Provider.ensure_default_for(owner) unless settings

      Provider.for_identifier(settings.user, settings.default_provider_identifier) || Provider.ensure_default_for(settings.user)
    end

    def provider_for_id(provider_id)
      return if provider_id.blank?

      Provider.find_by(id: provider_id)
    end

    # Returns nil for custom-prompt-only runs (no issue or PR) intentionally:
    # custom prompts are unique by definition and cannot be meaningfully deduplicated.
    def find_existing_run(project, issue, source_pull_request_number)
      scope = project.agent_runs.where(status: AgentRun::UNFINISHED_STATUSES).lock("FOR UPDATE")
      if issue
        scope.where(issue: issue).first
      elsif source_pull_request_number
        scope.where(source_pull_request_number: source_pull_request_number).first
      end
    end
  end
end
