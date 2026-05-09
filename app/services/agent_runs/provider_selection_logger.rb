# frozen_string_literal: true

module AgentRuns
  class ProviderSelectionLogger
    def self.call(...)
      new(...).call
    end

    def initialize(project:, goal:, resolved_agent_type:, resolved_provider_id:, issue: nil, agent_run: nil,
      requested_agent_type: nil, requested_provider_id: nil, respect_requested: false, outcome: "selected", error: nil)
      @project = project
      @goal = goal
      @resolved_agent_type = resolved_agent_type
      @resolved_provider_id = resolved_provider_id
      @issue = issue
      @agent_run = agent_run
      @requested_agent_type = requested_agent_type
      @requested_provider_id = requested_provider_id
      @respect_requested = respect_requested
      @outcome = outcome
      @error = error
    end

    def call
      OrchestrationDecision.record(
        project: project,
        issue: issue,
        agent_run: agent_run,
        action: "select_agent",
        decision_point: selection_source,
        status: decision_status,
        signals: inputs_payload,
        result: outputs_payload
      )
    end

    private

    attr_reader :project, :goal, :resolved_agent_type, :resolved_provider_id, :issue, :agent_run,
      :requested_agent_type, :requested_provider_id, :respect_requested, :outcome, :error

    def inputs_payload
      {
        "task" => {
          "goal" => goal,
          "issue_id" => issue&.id,
          "issue_title" => issue&.title,
          "custom_prompt_present" => agent_run&.custom_prompt.present?,
          "trigger_type" => agent_run&.trigger_type,
          "priority_tier" => agent_run&.priority_tier
        }.compact,
        "repository" => {
          "project_id" => project.id,
          "full_name" => project.full_name,
          "max_tokens_per_run" => project.max_tokens_per_run
        }.compact,
        "requested_selection" => {
          "provider_id" => requested_provider_id,
          "agent_type" => requested_agent_type,
          "respect_requested" => respect_requested
        }.compact,
        "policy_constraints" => {
          "preferred_agent_type" => preferences["preferred_agent_type"],
          "default_agent_provider" => settings&.default_agent_provider,
          "goal_default_agent_provider" => settings&.default_agent_providers_by_goal&.[](goal.to_s),
          "provider_selection_mode" => settings&.provider_selection_mode
        }.compact,
        "budget_signals" => {
          "active_budgets" => active_budget_signals
        }
      }
    end

    def outputs_payload
      {
        "outcome" => outcome,
        "selection" => selection_payload,
        "error" => error_payload
      }.compact
    end

    def selection_payload
      return if resolved_agent_type.blank? && resolved_provider_id.blank?

      provider = selected_provider
      {
        "provider_id" => resolved_provider_id,
        "provider_key" => provider&.provider_key || Provider.provider_key_for_agent_type(resolved_agent_type),
        "auth_type" => provider&.auth_type,
        "agent_type" => resolved_agent_type,
        "effective_provider" => provider&.provider_key || Provider.provider_key_for_agent_type(resolved_agent_type),
        "candidates" => ranked_candidates
      }.compact
    end

    def ranked_candidates
      candidates = []
      provider = selected_provider

      if resolved_agent_type.present? || provider.present?
        candidates << candidate_payload(
          provider: provider,
          agent_type: resolved_agent_type.presence || Provider.agent_type_for(provider&.provider_key),
          selected: true
        )
      end

      runnable_provider_candidates.each do |candidate_provider|
        next if provider && candidate_provider.id == provider.id

        candidates << candidate_payload(
          provider: candidate_provider,
          agent_type: Provider.agent_type_for(candidate_provider.provider_key),
          selected: false
        )
      end

      candidates.compact.each_with_index.map do |candidate, index|
        candidate.merge("rank" => index + 1)
      end
    end

    def candidate_payload(provider:, agent_type:, selected:)
      return if provider.nil? && agent_type.blank?

      {
        "selected" => selected,
        "provider_id" => provider&.id,
        "provider_key" => provider&.provider_key || Provider.provider_key_for_agent_type(agent_type),
        "auth_type" => provider&.auth_type,
        "agent_type" => agent_type
      }.compact
    end

    def runnable_provider_candidates
      owner = project.effective_owner
      return [] unless owner

      owner.providers.kept_only.ordered.select do |provider|
        provider.enabled_for_agent_runs? &&
          ProviderSupport.container_executable_provider_key?(provider.provider_key)
      end
    end

    def active_budget_signals
      project.cost_budgets.filter_map do |budget|
        next unless budget.limit_cents.to_i.positive?

        {
          "budget_type" => budget.budget_type,
          "enforcement_mode" => budget.enforcement_mode,
          "limit_cents" => budget.limit_cents,
          "remaining_cents" => budget.remaining_cents,
          "hard_stop" => budget.hard_stop?
        }
      end
    end

    def selected_provider
      @selected_provider ||= ProviderResolver.selected_provider(project: project, provider_id: resolved_provider_id)
    end

    def preferences
      @preferences ||= project.model_preferences || {}
    end

    def settings
      @settings ||= UserSettingsResolver.call(project: project, strict: false)
    end

    def selection_source
      preferred_agent_type = preferences["preferred_agent_type"]
      return "requested_provider" if requested_provider_selected?
      return "requested_agent_type" if requested_agent_type_selected?
      return "project_preferred_agent_type" if preferred_agent_type.present? && preferred_agent_type == resolved_agent_type

      "provider_selection"
    end

    def requested_provider_selected?
      requested_provider_id.present? && requested_provider_id.to_s == resolved_provider_id.to_s
    end

    def requested_agent_type_selected?
      requested_provider_id.blank? &&
        requested_agent_type.present? &&
        requested_agent_type == resolved_agent_type
    end

    def decision_status
      outcome == "selected" ? "applied" : "failed"
    end

    def error_payload
      return unless error

      {
        "class" => error.class.name,
        "message" => error.message
      }
    end
  end
end
