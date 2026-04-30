# frozen_string_literal: true

class TokenUsageTracker
  # Default pricing per million tokens (Claude Sonnet 4.6 fallback)
  DEFAULT_INPUT_COST_PER_MILLION = BigDecimal("3.00")
  DEFAULT_OUTPUT_COST_PER_MILLION = BigDecimal("15.00")

  # Tracks token usage for an agent run or knowledge run request.
  #
  # @param agent_run [AgentRun, nil] the agent run to attribute usage to
  # @param knowledge_run [KnowledgeRun, nil] the knowledge run to attribute usage to
  # @param usage [Hash] token data (:tokens_input, :tokens_output, :llm_model, :request_type, :metadata)
  # @param update_aggregates [Boolean] when false, only creates a TokenUsage record without
  #   updating agent_run/project counters or cost budgets (use for run_summary records
  #   that would otherwise double-count per-request tracking from the secrets proxy)
  # @param enforce_guardrails [Boolean] when false, updates aggregates without
  #   applying in-flight token/cost hard-stop behavior. Use for end-of-run
  #   summary reconciliation after the provider process has already exited.
  def self.track(agent_run: nil, knowledge_run: nil, chat_session: nil, usage:, update_aggregates: true, enforce_guardrails: true)
    tracked_run = resolve_tracked_run!(agent_run:, knowledge_run:, chat_session:)
    tokens_input  = usage.fetch(:tokens_input, 0).to_i
    tokens_output = usage.fetch(:tokens_output, 0).to_i
    llm_model     = usage[:llm_model]
    request_type  = usage.fetch(:request_type, nil).presence || default_request_type_for(tracked_run)
    metadata      = usage.fetch(:metadata, nil).presence || {}
    cost_cents    = calculate_cost(tokens_input, tokens_output, llm_model: llm_model)
    chat_session_run = tracked_run.is_a?(ChatSession)
    resolved_hard_limit = tracked_run.effective_max_tokens_per_run if update_aggregates && !chat_session_run

    ActiveRecord::Base.transaction do
      record_per_request_usage(
        agent_run: agent_run,
        knowledge_run: knowledge_run,
        chat_session: chat_session,
        input_tokens: tokens_input,
        output_tokens: tokens_output,
        cost_cents: cost_cents,
        llm_model: llm_model,
        request_type: request_type,
        metadata: metadata
      )

      if update_aggregates && !chat_session_run
        tracked_run.with_lock do
          update_run_aggregates(tracked_run, tokens_input:, tokens_output:, cost_cents:)
          apply_token_limit_status(tracked_run, hard_limit: resolved_hard_limit)
          tracked_run.save!
        end
      end

      if tracked_run.project
        tracked_run.project.increment_metrics!(
          cost_cents: cost_cents,
          tokens_used: tokens_input + tokens_output
        )

        update_cost_budgets(tracked_run.project, cost_cents)
      end

      record_usage_log(tracked_run, tokens_input:, tokens_output:, cost_cents:, llm_model:, request_type:)
    end

    # Enforce hard-stop budgets *after* the transaction commits so that:
    # 1. Row locks from the usage write are already released
    # 2. External side-effects (Temporal cancel, container cleanup) don't
    #    run inside a transaction — a failure won't roll back recorded usage
    enforce_hard_stop_budgets(tracked_run) if enforce_guardrails && update_aggregates && cost_cents.positive? && agent_run.present?
  end

  # Evaluates the agent run's cumulative token usage against project limits
  # and updates the token_limit_status field. Logs warnings at the soft
  # threshold and records "exceeded" at the hard limit.
  def self.apply_token_limit_status(tracked_run, hard_limit:)
    warning_threshold = tracked_run.project.token_limit_warning_threshold
    warning_at = (hard_limit * warning_threshold / 100.0).floor
    current_tokens = tracked_run.total_tokens

    new_status = if current_tokens >= hard_limit
      "exceeded"
    elsif current_tokens >= warning_at
      "warning"
    else
      "ok"
    end

    previous_status = tracked_run.token_limit_status

    return if new_status == previous_status

    tracked_run.token_limit_status = new_status

    if new_status == "warning" && previous_status != "warning"
      record_limit_log(tracked_run, "warning", current_tokens:, hard_limit:)
      Rails.logger.warn(
        log_payload_for(
          tracked_run,
          message: "#{logging_component_for(tracked_run)}.token_limit_warning",
          current_tokens: current_tokens,
          hard_limit: hard_limit,
          usage_percent: (current_tokens * 100.0 / hard_limit).round(1)
        )
      )
    elsif new_status == "exceeded"
      record_limit_log(tracked_run, "exceeded", current_tokens:, hard_limit:)
      Rails.logger.warn(
        log_payload_for(
          tracked_run,
          message: "#{logging_component_for(tracked_run)}.token_limit_exceeded",
          current_tokens: current_tokens,
          hard_limit: hard_limit
        )
      )
    end
  end
  private_class_method :apply_token_limit_status

  def self.log_payload_for(tracked_run, message:, **extra)
    {
      message: message,
      agent_run_id: tracked_run.is_a?(AgentRun) ? tracked_run.id : nil,
      knowledge_run_id: tracked_run.is_a?(KnowledgeRun) ? tracked_run.id : nil,
      chat_session_id: tracked_run.is_a?(ChatSession) ? tracked_run.id : nil
    }.merge(extra)
  end
  private_class_method :log_payload_for

  # Thread-safe in-memory cache of LlmModel records keyed by model_id string.
  # Avoids a DB query per tracked request in the high-volume proxy path.
  # Uses Concurrent::Map for safe concurrent access from Puma threads.
  # Only caches hits (not misses) so: (1) cache size is bounded to the number
  # of known LlmModel records, preventing DoS from arbitrary model strings;
  # (2) newly synced models are picked up on the next request without restart.
  @model_cache = Concurrent::Map.new

  def self.calculate_cost(input_tokens, output_tokens, llm_model: nil, model_id: nil)
    model = llm_model
    model = lookup_model(model) if model.is_a?(String)
    model ||= lookup_model(model_id) if model_id.present?

    if model&.input_cost_per_million && model&.output_cost_per_million
      model.estimated_cost(input_tokens, output_tokens)
    else
      input_cost = BigDecimal(input_tokens.to_s) / BigDecimal("1000000") * DEFAULT_INPUT_COST_PER_MILLION
      output_cost = BigDecimal(output_tokens.to_s) / BigDecimal("1000000") * DEFAULT_OUTPUT_COST_PER_MILLION
      ((input_cost + output_cost) * 100).round.to_i
    end
  end

  # Clears the cached model pricing data. Called by Models::SeedKnownModels
  # after syncing so updated pricing takes effect without process restart.
  def self.clear_model_cache!
    @model_cache.clear
  end

  def self.lookup_model(model_id)
    return nil if model_id.blank?

    @model_cache.fetch(model_id) do
      LlmModel.find_by(model_id: model_id)&.tap { |m| @model_cache[model_id] = m }
    end
  end
  private_class_method :lookup_model

  def self.record_per_request_usage(agent_run:, knowledge_run:, chat_session: nil, input_tokens:, output_tokens:, cost_cents:, llm_model:, request_type:, metadata:)
    TokenUsage.create!(
      agent_run: agent_run,
      knowledge_run: knowledge_run,
      chat_session: chat_session,
      input_tokens: input_tokens,
      output_tokens: output_tokens,
      cost_cents: cost_cents,
      llm_model: llm_model,
      request_type: request_type,
      metadata: metadata
    )
  end
  private_class_method :record_per_request_usage

  def self.resolve_tracked_run!(agent_run:, knowledge_run:, chat_session: nil)
    return agent_run if agent_run.present? && knowledge_run.blank? && chat_session.blank?
    return knowledge_run if knowledge_run.present? && agent_run.blank? && chat_session.blank?
    return chat_session if chat_session.present? && agent_run.blank? && knowledge_run.blank?

    raise ArgumentError, "expected exactly one of agent_run, knowledge_run, or chat_session"
  end
  private_class_method :resolve_tracked_run!

  def self.update_run_aggregates(tracked_run, tokens_input:, tokens_output:, cost_cents:)
    if tracked_run.is_a?(AgentRun)
      tracked_run.increment(:tokens_input, tokens_input)
      tracked_run.increment(:tokens_output, tokens_output)
      tracked_run.increment(:cost_cents, cost_cents)
    else
      tracked_run.increment(:total_tokens, tokens_input + tokens_output)
    end
  end
  private_class_method :update_run_aggregates

  def self.default_request_type_for(tracked_run)
    case tracked_run
    when KnowledgeRun then "knowledge"
    when ChatSession then "chat"
    else "agent"
    end
  end
  private_class_method :default_request_type_for

  def self.record_usage_log(tracked_run, tokens_input:, tokens_output:, cost_cents:, llm_model:, request_type:)
    return unless tracked_run.is_a?(AgentRun)

    tracked_run.log!("metric", {
      tokens_input: tokens_input,
      tokens_output: tokens_output,
      cost_cents: cost_cents,
      llm_model: llm_model,
      request_type: request_type
    }.to_json, metadata: { type: "token_usage" })
  end
  private_class_method :record_usage_log

  def self.record_limit_log(tracked_run, state, current_tokens:, hard_limit:)
    return unless tracked_run.is_a?(AgentRun)

    message =
      if state == "warning"
        "Token usage warning: #{current_tokens} of #{hard_limit} tokens used " \
          "(#{(current_tokens * 100.0 / hard_limit).round(1)}%). " \
          "Run will be stopped at #{hard_limit} tokens."
      else
        "Token limit exceeded: #{current_tokens} of #{hard_limit} tokens used. " \
          "Agent will be stopped after the current operation completes."
      end

    tracked_run.log!(
      "system",
      message,
      metadata: { type: "token_limit_#{state}" }
    )
  end
  private_class_method :record_limit_log

  def self.logging_component_for(tracked_run)
    case tracked_run
    when KnowledgeRun then "knowledge_execution"
    when ChatSession then "chat_execution"
    else "agent_execution"
    end
  end
  private_class_method :logging_component_for

  def self.update_cost_budgets(project, cost_cents)
    # Only update daily/monthly budgets. Per-run budgets are enforced by
    # summing agent_run.token_usages (not current_usage_cents), so updating
    # the counter here would cause it to drift upward across runs and
    # trigger misleading threshold alerts.
    project.cost_budgets.where(budget_type: %w[daily monthly]).find_each do |budget|
      budget.record_usage!(cost_cents)
    end
  end
  private_class_method :update_cost_budgets

  # Checks hard_stop budgets after recording usage. If any budget is
  # exceeded, cancels the running agent to enforce the cost limit.
  # Short-circuits when the project has no hard-stop budgets to avoid
  # unnecessary queries on every token-tracking request.
  def self.enforce_hard_stop_budgets(agent_run)
    return unless AgentRun.where(id: agent_run.id, status: "running").exists?
    return unless agent_run.project.cost_budgets.hard_stop.exists?

    result = CostBudgets::Check.call(agent_run.project, agent_run: agent_run)
    return if result[:allowed]

    Rails.logger.warn(
      message: "cost_budget.hard_stop_enforced",
      agent_run_id: agent_run.id,
      reason: result[:reason]
    )

    violation_result = Guardrails::ViolationHandler.call(
      agent_run: agent_run,
      violation_type: "cost_limit",
      details: result[:reason],
      metrics: { budget_reason: result[:reason] }
    )

    # If pause succeeded, or another guardrail already paused the run before
    # this handler returned, preserve the paused state for user review.
    # Otherwise fall back to the original cancel-and-fail behavior.
    unless violation_result.paused? || agent_run.paused?
      begin
        AgentRuns::Cancel.call(agent_run: agent_run, skip_status_update: true)
      rescue => e
        Rails.logger.error(
          message: "cost_budget.hard_stop_cancel_failed",
          agent_run_id: agent_run.id,
          reason: result[:reason],
          error_class: e.class.name,
          error_message: e.message
        )
      ensure
        agent_run.fail!(error: "Budget enforcement: #{result[:reason]}") unless agent_run.finished?
      end
    end
  end
  private_class_method :enforce_hard_stop_budgets
end
