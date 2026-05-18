# frozen_string_literal: true

module Models
  class Select
    include ProviderTierLookup

    DECISION_LOG_TYPE = "model_selection_decision"

    attr_reader :agent_run

    def self.call(...)
      new(...).call
    end

    def initialize(agent_run:)
      @agent_run = agent_run
    end

    def call
      start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      if skip_model_selection?
        persist_decision_log(outcome: "no_selection", duration_ms: 0)
        return nil
      end

      selected = select_model
      duration_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time) * 1000).round
      unless selected
        persist_decision_log(outcome: "no_selection", duration_ms: duration_ms)
        return nil
      end

      final_tier = selected[:tier] || tier_for(selected)
      escalation = detect_escalation(selected, final_tier)
      candidates = normalized_candidates(selected, selected_model_id: selected[:model].model_id)

      selection = ModelSelection.find_or_create_by!(agent_run: agent_run) do |ms|
        ms.llm_model = selected[:model]
        ms.selector_type = selected[:selector_type]
        ms.reasoning = selected[:reasoning]
        ms.candidates = candidates
        ms.complexity_score = selected[:complexity_score]
        ms.tier = final_tier
        ms.selection_duration_ms = duration_ms
        ms.escalated_from_tier = escalation[:from_tier]
        ms.escalated_reason = escalation[:reason]
      end
      persist_decision_log(
        outcome: "selected",
        duration_ms: duration_ms,
        selected: selected,
        final_tier: final_tier,
        escalation: escalation,
        selection: selection,
        candidates: candidates
      )
      selection
    rescue ActiveRecord::RecordNotUnique
      ModelSelection.find_by!(agent_run: agent_run)
    rescue => e
      duration_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time) * 1000).round
      persist_decision_log(outcome: "failed", duration_ms: duration_ms, error: e)
      raise
    end

    private

    def skip_model_selection?
      provider = agent_run.provider
      provider&.provider_key == "codex" && provider.subscription?
    end

    def select_model
      project = agent_run.project

      # Check for project-level model override
      if project.model_preferences["required_model_id"].present?
        model = LlmModel.active.find_by(model_id: project.model_preferences["required_model_id"])
        return override_result(model, "Project requires specific model") if model
      end

      quality_escalation = quality_escalation_result(project)
      return quality_escalation if quality_escalation

      # Check for preferred models
      preferred = preferred_model_result(project)
      return preferred if preferred

      tenant_preferred = tenant_model_preference_result(project)
      return tenant_preferred if tenant_preferred

      # Try meta-agent selection, fall back to rules-based
      Models::MetaAgentSelector.call(agent_run: agent_run) ||
        Models::RulesBasedSelector.call(agent_run: agent_run)
    end

    def quality_escalation_result(project)
      tier = QualityRecovery::ModelEscalation.target_tier(project)
      return nil unless tier

      excluded = project.model_preferences["excluded_model_ids"]
      provider_model = provider_tier_model(tier)
      provider_model = nil if provider_model && excluded_model?(provider_model, excluded)
      scope = LlmModel.active.by_tier(tier).by_capability
      scope = scope.where.not(model_id: excluded) if excluded.present?
      model = provider_model || scope.first
      return nil unless model

      {
        model: model,
        selector_type: "quality_escalation",
        reasoning: "Quality-triggered escalation to #{tier} tier",
        candidates: [ model ],
        complexity_score: nil,
        tier: tier
      }
    end

    def preferred_model_result(project)
      preferred_ids = project.model_preferences["preferred_model_ids"]
      return nil unless preferred_ids.is_a?(Array) && preferred_ids.any?

      # Respect preference list ordering: select the first active model in the provided order
      models_by_id = LlmModel.active.where(model_id: preferred_ids).index_by(&:model_id)
      model = preferred_ids.map { |id| models_by_id[id] }.compact.first
      return nil unless model

      override_result(model, "Project preferred model: #{model.display_name}")
    end

    def tenant_model_preference_result(project)
      model_id = project.account.tenant_setting&.model_preference_for(agent_run.effective_provider)
      return nil if model_id.blank?

      model = LlmModel.active.find_by(model_id: model_id)
      return nil unless model

      override_result(model, "Tenant preferred model: #{model.display_name}")
    end

    def override_result(model, reason)
      {
        model: model,
        selector_type: "override",
        reasoning: reason,
        candidates: [ model ],
        complexity_score: nil,
        # For override paths the tier follows the chosen model directly, since
        # no complexity-based routing was performed.
        tier: model.tier
      }
    end

    # Recorded tier for a selection. Prefers the selector's own tier (derived
    # from the complexity->tier mapping it used) and falls back to the model's
    # own tier so ModelSelection.tier is populated for every run, even when the
    # complexity score is absent (override paths).
    def tier_for(selected)
      return nil if selected.blank?

      selected[:tier].presence || selected[:model]&.tier
    end

    # Detects whether the final tier was escalated above the complexity-derived
    # tier due to quality recovery min tier settings (project-wide or per-goal).
    def detect_escalation(selected, final_tier)
      return { from_tier: nil, reason: nil } if selected[:selector_type] == "override"
      return { from_tier: nil, reason: nil } unless final_tier && selected[:complexity_score]

      base_tier = base_tier_for(selected[:complexity_score])
      return { from_tier: nil, reason: nil } unless base_tier

      base_index = LlmModel::TIERS.index(base_tier)
      final_index = LlmModel::TIERS.index(final_tier)
      return { from_tier: nil, reason: nil } unless base_index && final_index && final_index > base_index

      reason = escalation_reason
      return { from_tier: nil, reason: nil } unless reason

      { from_tier: base_tier, reason: reason }
    end

    def base_tier_for(complexity_score)
      Models::TierForComplexity.call(
        complexity: complexity_score,
        provider: agent_run.provider
      )
    end

    def escalation_reason
      project = agent_run.project
      goal = agent_run.goal

      if project.model_preferences&.dig("goal_min_tiers", goal).present?
        "quality_recovery_goal"
      elsif project.model_preferences&.dig("quality_recovery_min_tier").present?
        "quality_recovery_project"
      end
    end

    def normalized_candidates(selected, selected_model_id:)
      Array(selected[:candidates]).filter_map.with_index(1) do |candidate, rank|
        normalize_candidate(candidate, rank: rank, selected_model_id: selected_model_id)
      end
    end

    def normalize_candidate(candidate, rank:, selected_model_id:)
      if candidate.is_a?(LlmModel)
        serialize_model_candidate(candidate, rank: rank, selected: candidate.model_id == selected_model_id)
      elsif candidate.respond_to?(:deep_symbolize_keys)
        data = candidate.deep_symbolize_keys
        model = LlmModel.find_by(model_id: data[:model_id])
        serialize_hash_candidate(data, model: model, rank: rank, selected_model_id: selected_model_id)
      end
    end

    def serialize_hash_candidate(data, model:, rank:, selected_model_id:)
      {
        rank: rank,
        selected: data.fetch(:selected, data[:model_id] == selected_model_id),
        model_id: data[:model_id],
        provider: data[:provider] || model&.provider,
        tier: data[:tier] || model&.tier,
        score: data[:score],
        capability_score: data[:capability_score] || model&.capability_score&.to_f,
        input_cost_per_million: data[:input_cost_per_million] || model&.input_cost_per_million&.to_f,
        output_cost_per_million: data[:output_cost_per_million] || model&.output_cost_per_million&.to_f
      }.compact
    end

    def serialize_model_candidate(model, rank:, selected:)
      {
        rank: rank,
        selected: selected,
        model_id: model.model_id,
        provider: model.provider,
        tier: model.tier,
        score: model.capability_score&.to_f,
        capability_score: model.capability_score&.to_f,
        input_cost_per_million: model.input_cost_per_million&.to_f,
        output_cost_per_million: model.output_cost_per_million&.to_f
      }.compact
    end

    def persist_decision_log(outcome:, duration_ms:, selected: nil, final_tier: nil, escalation: nil, selection: nil, candidates: nil, error: nil)
      selection_payload = selection_payload(
        selected: selected,
        selection: selection,
        final_tier: final_tier,
        escalation: escalation,
        candidates: candidates
      )
      inputs_payload = selection_inputs

      persist_orchestration_decision_safely(
        outcome: outcome,
        duration_ms: duration_ms,
        selected: selected,
        selection_payload: selection_payload,
        inputs_payload: inputs_payload,
        error: error
      )
      persist_agent_run_decision_log(
        outcome: outcome,
        duration_ms: duration_ms,
        selected: selected,
        selection_payload: selection_payload,
        inputs_payload: inputs_payload,
        error: error
      )
    end

    def persist_agent_run_decision_log(outcome:, duration_ms:, selected:, selection_payload:, inputs_payload:, error:)
      agent_run.agent_run_logs.create!(
        log_type: "system",
        content: decision_log_content(outcome: outcome, selected: selected, error: error),
        metadata: {
          type: DECISION_LOG_TYPE,
          outcome: outcome,
          duration_ms: duration_ms,
          selection: selection_payload,
          inputs: inputs_payload,
          error: error_payload(error)
        }.compact
      )
    rescue => log_error
      Rails.logger.warn(
        message: "model_selection.decision_log_failed",
        agent_run_id: agent_run.id,
        error_class: log_error.class.name,
        error: log_error.message
      )
    end

    def persist_orchestration_decision_safely(outcome:, duration_ms:, selected:, selection_payload:, inputs_payload:, error:)
      persist_orchestration_decision(
        outcome: outcome,
        duration_ms: duration_ms,
        selected: selected,
        selection_payload: selection_payload,
        inputs_payload: inputs_payload,
        error: error
      )
    rescue => log_error
      Rails.logger.warn(
        message: "model_selection.orchestration_decision_failed",
        agent_run_id: agent_run.id,
        error_class: log_error.class.name,
        error: log_error.message
      )
    end

    def decision_log_content(outcome:, selected:, error:)
      case outcome
      when "selected"
        "Agent selection succeeded via #{selected[:selector_type]} for #{selected[:model].model_id}"
      when "no_selection"
        "Agent selection found no eligible models"
      else
        "Agent selection failed: #{error.class}: #{error.message}"
      end
    end

    def selection_payload(selected:, selection:, final_tier:, escalation:, candidates:)
      return nil unless selected || selection

      {
        model_selection_id: selection&.id,
        agent_type: agent_run.agent_type,
        provider_id: agent_run.provider_id,
        provider_key: agent_run.provider&.provider_key || agent_run.effective_provider,
        effective_provider: agent_run.effective_provider,
        selector_type: selected&.dig(:selector_type) || selection&.selector_type,
        reasoning: selected&.dig(:reasoning) || selection&.reasoning,
        model_id: selected&.dig(:model)&.model_id || selection&.llm_model&.model_id,
        model_provider: selected&.dig(:model)&.provider || selection&.llm_model&.provider,
        model_tier: selected&.dig(:model)&.tier || selection&.llm_model&.tier,
        final_tier: final_tier || selection&.tier,
        complexity_score: selected&.dig(:complexity_score) || selection&.complexity_score&.to_f,
        escalated_from_tier: escalation&.dig(:from_tier) || selection&.escalated_from_tier,
        escalated_reason: escalation&.dig(:reason) || selection&.escalated_reason,
        candidates: candidates || selection&.candidates
      }.compact
    end

    def selection_inputs
      project = agent_run.project
      issue = agent_run.issue
      preferences = project.model_preferences || {}
      provider = agent_run.provider

      {
        task: {
          goal: agent_run.goal,
          trigger_type: agent_run.trigger_type,
          issue_id: issue&.id,
          issue_title: issue&.title,
          issue_body_length: issue&.body.to_s.length,
          custom_prompt_present: agent_run.custom_prompt.present?,
          existing_pr: agent_run.existing_pr?,
          priority_tier: agent_run.priority_tier
        }.compact,
        repository: {
          project_id: project.id,
          full_name: project.full_name,
          max_tokens_per_run: project.max_tokens_per_run
        }.compact,
        provider_context: {
          provider_id: provider&.id,
          provider_key: provider&.provider_key || agent_run.effective_provider,
          agent_type: agent_run.agent_type,
          effective_provider: agent_run.effective_provider,
          complexity_thresholds: Models::TierForComplexity.new(agent_run: agent_run, complexity: 1.0).effective_thresholds
        }.compact,
        policy_constraints: {
          required_model_id: preferences["required_model_id"],
          preferred_model_ids: preferences["preferred_model_ids"],
          excluded_model_ids: preferences["excluded_model_ids"],
          max_tier: preferences["max_tier"],
          quality_recovery_min_tier: preferences["quality_recovery_min_tier"],
          goal_min_tier: preferences.dig("goal_min_tiers", agent_run.goal),
          preferred_agent_type: preferences["preferred_agent_type"]
        }.compact,
        budget_signals: {
          active_budgets: active_budget_signals(project)
        }
      }
    end

    def active_budget_signals(project)
      project.cost_budgets.filter_map do |budget|
        next unless budget.limit_cents.to_i.positive?

        {
          budget_type: budget.budget_type,
          enforcement_mode: budget.enforcement_mode,
          limit_cents: budget.limit_cents,
          remaining_cents: budget.remaining_cents,
          hard_stop: budget.hard_stop?
        }
      end
    end

    def error_payload(error)
      return nil unless error

      {
        class: error.class.name,
        message: error.message
      }
    end

    def persist_orchestration_decision(outcome:, duration_ms:, selected:, selection_payload:, inputs_payload:, error:)
      OrchestrationDecision.record(
        project: agent_run.project,
        issue: agent_run.issue,
        agent_run: agent_run,
        action: "select_agent",
        decision_point: selected&.dig(:selector_type) || "model_selection",
        status: orchestration_status_for(outcome),
        signals: inputs_payload.merge(
          "duration_ms" => duration_ms
        ),
        result: {
          "outcome" => outcome,
          "selection" => selection_payload,
          "error" => error_payload(error)
        }.compact
      )
    end

    def orchestration_status_for(outcome)
      case outcome
      when "selected"
        "applied"
      when "no_selection"
        "noop"
      else
        "failed"
      end
    end
  end
end
