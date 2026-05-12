# frozen_string_literal: true

module AgentRuns
  class RunnerSelectionLogger
    def self.call(...)
      new(...).call
    end

    def initialize(project:, goal:, resolved_agent_type:, resolved_runner_id:, issue: nil, agent_run: nil,
      requested_agent_type: nil, requested_runner_id: nil, respect_requested: false, outcome: "selected", error: nil)
      @project = project
      @goal = goal
      @resolved_agent_type = resolved_agent_type
      @resolved_runner_id = resolved_runner_id
      @issue = issue
      @agent_run = agent_run
      @requested_agent_type = requested_agent_type
      @requested_runner_id = requested_runner_id
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

    attr_reader :project, :goal, :resolved_agent_type, :resolved_runner_id, :issue, :agent_run,
      :requested_agent_type, :requested_runner_id, :respect_requested, :outcome, :error

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
          "runner_id" => requested_runner_id,
          "agent_type" => requested_agent_type,
          "respect_requested" => respect_requested
        }.compact,
        "policy_constraints" => {
          "preferred_agent_type" => preferences["preferred_agent_type"],
          "default_agent_runner" => settings&.default_agent_runner,
          "goal_default_agent_runner" => settings&.default_agent_runners_by_goal&.[](goal.to_s),
          "runner_selection_mode" => settings&.runner_selection_mode
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
      return if resolved_agent_type.blank? && resolved_runner_id.blank?

      runner = selected_runner
      {
        "runner_id" => resolved_runner_id,
        "runner_key" => runner&.runner_key || Runner.runner_key_for_agent_type(resolved_agent_type),
        "auth_type" => runner&.auth_type,
        "agent_type" => resolved_agent_type,
        "effective_runner" => runner&.runner_key || Runner.runner_key_for_agent_type(resolved_agent_type),
        "candidates" => ranked_candidates
      }.compact
    end

    def ranked_candidates
      candidates = []
      runner = selected_runner

      if resolved_agent_type.present? || runner.present?
        candidates << candidate_payload(
          runner: runner,
          agent_type: resolved_agent_type.presence || Runner.agent_type_for(runner&.runner_key),
          selected: true
        )
      end

      runnable_runner_candidates.each do |candidate_runner|
        next if runner && candidate_runner.id == runner.id

        candidates << candidate_payload(
          runner: candidate_runner,
          agent_type: Runner.agent_type_for(candidate_runner.runner_key),
          selected: false
        )
      end

      candidates.compact.each_with_index.map do |candidate, index|
        candidate.merge("rank" => index + 1)
      end
    end

    def candidate_payload(runner:, agent_type:, selected:)
      return if runner.nil? && agent_type.blank?

      {
        "selected" => selected,
        "runner_id" => runner&.id,
        "runner_key" => runner&.runner_key || Runner.runner_key_for_agent_type(agent_type),
        "auth_type" => runner&.auth_type,
        "agent_type" => agent_type
      }.compact
    end

    def runnable_runner_candidates
      owner = project.effective_owner
      return [] unless owner

      owner.runners.kept_only.ordered.select do |runner|
        runner.enabled_for_agent_runs? &&
          RunnerSupport.container_executable_runner_key?(runner.runner_key)
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

    def selected_runner
      @selected_runner ||= RunnerResolver.selected_runner(project: project, runner_id: resolved_runner_id)
    end

    def preferences
      @preferences ||= project.model_preferences || {}
    end

    def settings
      @settings ||= UserSettingsResolver.call(project: project, strict: false)
    end

    def selection_source
      preferred_agent_type = preferences["preferred_agent_type"]
      return "requested_runner" if requested_runner_selected?
      return "requested_agent_type" if requested_agent_type_selected?
      return "project_preferred_agent_type" if preferred_agent_type.present? && preferred_agent_type == resolved_agent_type

      "runner_selection"
    end

    def requested_runner_selected?
      requested_runner_id.present? && requested_runner_id.to_s == resolved_runner_id.to_s
    end

    def requested_agent_type_selected?
      requested_runner_id.blank? &&
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
