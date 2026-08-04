# frozen_string_literal: true

module Models
  # @spec MODEL-SELECTION-001, MODEL-SELECTION-004
  class Select
    include RunnerTierLookup

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
      block_reason = llm_provider_block_reason(selected)
      no_selection_reason = block_reason || no_selection_reason_for(selected)
      unless selected && compatible_selection?(selected) && no_selection_reason.nil?
        persist_decision_log(outcome: "no_selection", duration_ms: duration_ms, selected: selected, no_selection_reason: no_selection_reason)
        return nil
      end

      policy_result = Guardrails::DataClassificationPolicy.call(agent_run: agent_run, selection: selected)
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
        policy_result: policy_result,
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
      provider&.provider_key == "codex" && provider&.subscription?
    end

    def select_model
      project = agent_run.project

      # Check for project-level model override
      if project.model_preferences["required_model_id"].present?
        model = LlmModel.active.find_by(model_id: project.model_preferences["required_model_id"])
        candidate = override_compatible_or_nil(model)
        if candidate.is_a?(Hash) && candidate[:incompatibility_reason]
          # RDR-040: surface an explicit "incompatible with runner" outcome so
          # the no-selection decision log can record both the model and the
          # rejection reason. Returning the hash (with the sentinel) lets
          # `call` continue to the no-selection branch without losing the
          # model id from the log.
          return candidate
        end
        return override_result(candidate, "Project requires specific model") if candidate
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

    # RDR-040: When a runner is already bound to the run (e.g. a pinned or
    # late-bound runner), the override paths must additionally validate the
    # candidate against the runner's compatibility contract — not just the
    # catalog — before declaring success. Returns the model (so the
    # override_result carries the model_id into the decision log) but marks
    # it with an :incompatibility_reason sentinel so the no-selection path
    # can record the rejection with a clear reason. The unauthenticated/
    # no-runner case is left permissive so Models::Select can still produce
    # a selection that later Runners::ResolveTierModel validates against
    # the resolved runner.
    def override_compatible_or_nil(model)
      return model if !model || !agent_run.runner

      result = runner_compatibility_result(model)
      return model unless result&.unsupported?

      runner = agent_run.runner
      reason = result.reason || "model '#{model.model_id}' is not compatible with runner '#{runner.runner_key}'"
      {
        model: model,
        selector_type: "override",
        reasoning: "Project requires specific model",
        candidates: [ model ],
        complexity_score: nil,
        tier: model.tier,
        incompatibility_reason: "model '#{model.model_id}' is not compatible with runner '#{runner.runner_key}' (#{reason})"
      }
    end

    def quality_escalation_result(project)
      tier = QualityRecovery::ModelEscalation.target_tier(project)
      return nil unless tier

      excluded = project.model_preferences["excluded_model_ids"]
      runner_model = runner_tier_model(tier)
      runner_model = nil if runner_model && disallowed_model?(runner_model, excluded)
      scope = LlmModel.active.by_tier(tier).by_capability
      scope = compatible_model_scope(scope)
      scope = scope.where.not(model_id: excluded) if excluded.present?
      model = runner_model || scope.first
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

      # Respect preference list ordering: select the first active, project-permitted
      # model in the provided order (skip models whose provider the project blocks
      # and skip models incompatible with the bound runner when one is present).
      models_by_id = LlmModel.active.where(model_id: preferred_ids).index_by(&:model_id)
      model = preferred_ids
        .map { |id| models_by_id[id] }
        .compact
        .find do |candidate|
          project.llm_provider_allowed?(candidate.provider) && runner_compatible?(candidate)
        end
      return nil unless model

      override_result(model, "Project preferred model: #{model.display_name}")
    end

    def tenant_model_preference_result(project)
      model_id = project.account.tenant_setting&.model_preference_for(agent_run.effective_runner)
      return nil if model_id.blank?

      model = LlmModel.active.find_by(model_id: model_id)
      return nil unless model
      return nil if project.llm_provider_blocked?(model.provider)
      return nil unless runner_compatible?(model)

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
        runner: agent_run.runner
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

    def compatible_selection?(selected)
      model = selected[:model]
      runner = agent_run.runner
      return true unless model && runner
      return model.free? if free_tier_constrained_runner?
      return true unless constrained_runner_selection?(runner)

      configured_model_id = runner.direct_outbound_model_id
      return model.model_id == configured_model_id if configured_model_id.present?

      compatible_provider = runner.direct_outbound_llm_model_provider.presence ||
        Runners::DefaultTierModelIds::RUNNER_KEY_TO_MODEL_PROVIDER[runner.runner_key.to_s]
      return true if compatible_provider.blank?

      model.provider == compatible_provider
    end

    # RDR-040: Use the broader runner compatibility contract to validate the
    # selected model. The direct-outbound checks in #compatible_selection? only
    # catch wrong-provider mistakes; they miss CLI-version-gated models,
    # auth-mode-gated models, and unknown runner/model mismatches that the
    # agent-harness contract would catch statically. Applies to ALL runners
    # (subscription, api_key, direct-outbound) so override paths can fail
    # loudly before burning queue time.
    def runner_compatible?(model)
      result = runner_compatibility_result(model)
      return true unless result

      !result.unsupported?
    end

    def runner_compatibility_result(model)
      runner = agent_run.runner
      return nil unless model && runner

      Runners::ModelCompatibility.call(
        runner_key: runner.runner_key,
        model_id: model.model_id,
        auth_type: runner.auth_type,
        provider_runtime: runner.agent_harness_runner_runtime
      )
    end

    def constrained_runner_selection?(runner)
      runner.requires_direct_outbound? ||
        (runner.runner_key == "pi" && runner.api_key? && runner.pi_required_api_service_type.present?)
    end

    # A model is disallowed when the project excluded it by id or when its LLM
    # provider is blocked by the project's per-provider allowlist/blocklist.
    def disallowed_model?(model, excluded)
      excluded_model?(model, excluded) || agent_run.project.llm_provider_blocked?(model.provider)
    end

    # Returns a clear, human-readable reason when the selected model's LLM
    # provider is not permitted for the project, or nil when it is allowed /
    # no model was selected. Surfaced as the no-selection decision reason.
    def llm_provider_block_reason(selected)
      model = selected&.dig(:model)
      return nil unless model

      project = agent_run.project
      return nil unless project.llm_provider_blocked?(model.provider)

      mode = project.llm_provider_routing_mode
      "LLM provider '#{model.provider}' is not permitted for this project " \
        "(#{mode} restriction)"
    end

    # RDR-040: Surfaces a runner/model compatibility failure for override
    # paths so the no-selection log shows a clear reason instead of the
    # generic "Agent selection found no eligible models". Returns the
    # override path's pre-computed reason when available (set by
    # override_compatible_or_nil) so the decision log can include the
    # specific model and runner names. The override selectors above
    # already filter candidates against runner compatibility (so an
    # override result is normally runner-compatible), but a late change
    # to the catalog or the runner between resolve and dispatch can
    # still produce a stale selection. This is the final consistency
    # check.
    def no_selection_reason_for(selected)
      return selected[:incompatibility_reason] if selected.is_a?(Hash) && selected[:incompatibility_reason].present?

      model = selected&.dig(:model)
      return nil unless model

      result = runner_compatibility_result(model)
      return nil unless result&.unsupported?

      runner = agent_run.runner
      reason = result.reason || "model '#{model.model_id}' is not compatible with runner '#{runner.runner_key}'"
      "model '#{model.model_id}' is not compatible with runner '#{runner.runner_key}' (#{reason})"
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

    def persist_decision_log(outcome:, duration_ms:, selected: nil, policy_result: nil, final_tier: nil, escalation: nil, selection: nil, candidates: nil, error: nil, no_selection_reason: nil)
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
        policy_result: policy_result,
        selection_payload: selection_payload,
        inputs_payload: inputs_payload,
        error: error,
        no_selection_reason: no_selection_reason
      )
      persist_agent_run_decision_log(
        outcome: outcome,
        duration_ms: duration_ms,
        selected: selected,
        selection_payload: selection_payload,
        inputs_payload: inputs_payload,
        error: error,
        no_selection_reason: no_selection_reason
      )
    end

    def persist_agent_run_decision_log(outcome:, duration_ms:, selected:, selection_payload:, inputs_payload:, error:, no_selection_reason: nil)
      agent_run.agent_run_logs.create!(
        log_type: "system",
        content: decision_log_content(outcome: outcome, selected: selected, error: error, no_selection_reason: no_selection_reason),
        metadata: {
          type: DECISION_LOG_TYPE,
          outcome: outcome,
          duration_ms: duration_ms,
          reason: no_selection_reason,
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

    def persist_orchestration_decision_safely(outcome:, duration_ms:, selected:, policy_result:, selection_payload:, inputs_payload:, error:, no_selection_reason: nil)
      persist_orchestration_decision(
        outcome: outcome,
        duration_ms: duration_ms,
        selected: selected,
        policy_result: policy_result,
        selection_payload: selection_payload,
        inputs_payload: inputs_payload,
        error: error,
        no_selection_reason: no_selection_reason
      )
    rescue => log_error
      Rails.logger.warn(
        message: "model_selection.orchestration_decision_failed",
        agent_run_id: agent_run.id,
        error_class: log_error.class.name,
        error: log_error.message
      )
    end

    def decision_log_content(outcome:, selected:, error:, no_selection_reason: nil)
      case outcome
      when "selected"
        "Agent selection succeeded via #{selected[:selector_type]} for #{selected[:model].model_id}"
      when "no_selection"
        no_selection_reason || "Agent selection found no eligible models"
      else
        "Agent selection failed: #{error.class}: #{error.message}"
      end
    end

    def selection_payload(selected:, selection:, final_tier:, escalation:, candidates:)
      return nil unless selected || selection

      {
        model_selection_id: selection&.id,
        agent_type: agent_run.agent_type,
        runner_id: agent_run.runner_id,
        runner_key: agent_run.runner&.runner_key || agent_run.effective_runner,
        provider_key: agent_run.runner&.runner_key || agent_run.effective_runner,
        effective_runner: agent_run.effective_runner,
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
      runner = agent_run.runner

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
        runner_context: {
          runner_id: runner&.id,
          runner_key: runner&.runner_key || agent_run.effective_runner,
          agent_type: agent_run.agent_type,
          effective_runner: agent_run.effective_runner,
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

    def persist_orchestration_decision(outcome:, duration_ms:, selected:, policy_result:, selection_payload:, inputs_payload:, error:, no_selection_reason: nil)
      OrchestrationDecision.record(
        project: agent_run.project,
        issue: agent_run.issue,
        agent_run: agent_run,
        action: "select_agent",
        decision_point: selected&.dig(:selector_type) || "model_selection",
        status: orchestration_status_for(outcome),
        context: policy_result&.context || {},
        signals: inputs_payload.merge(
          "duration_ms" => duration_ms
        ),
        result: {
          "outcome" => outcome,
          "reason" => no_selection_reason,
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
