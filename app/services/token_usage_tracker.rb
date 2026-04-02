# frozen_string_literal: true

class TokenUsageTracker
  # Default pricing per million tokens (Claude Sonnet 4.6 fallback)
  DEFAULT_INPUT_COST_PER_MILLION = BigDecimal("3.00")
  DEFAULT_OUTPUT_COST_PER_MILLION = BigDecimal("15.00")

  # Tracks token usage for an agent run request.
  #
  # @param agent_run [AgentRun] the run to attribute usage to
  # @param usage [Hash] token data (:tokens_input, :tokens_output, :llm_model, :request_type, :metadata)
  # @param update_aggregates [Boolean] when false, only creates a TokenUsage record without
  #   updating agent_run/project counters or cost budgets (use for run_summary records
  #   that would otherwise double-count per-request tracking from the secrets proxy)
  def self.track(agent_run:, usage:, update_aggregates: true)
    tokens_input  = usage.fetch(:tokens_input, 0).to_i
    tokens_output = usage.fetch(:tokens_output, 0).to_i
    llm_model     = usage[:llm_model]
    request_type  = usage.fetch(:request_type, nil).presence || "agent"
    metadata      = usage.fetch(:metadata, nil).presence || {}
    cost_cents    = calculate_cost(tokens_input, tokens_output, llm_model: llm_model)

    ActiveRecord::Base.transaction do
      record_per_request_usage(
        agent_run: agent_run,
        input_tokens: tokens_input,
        output_tokens: tokens_output,
        cost_cents: cost_cents,
        llm_model: llm_model,
        request_type: request_type,
        metadata: metadata
      )

      if update_aggregates
        agent_run.with_lock do
          agent_run.increment(:tokens_input, tokens_input)
          agent_run.increment(:tokens_output, tokens_output)
          agent_run.increment(:cost_cents, cost_cents)
          agent_run.save!

          check_token_limits(agent_run)
        end

        agent_run.project.increment_metrics!(
          cost_cents: cost_cents,
          tokens_used: tokens_input + tokens_output
        )

        update_cost_budgets(agent_run.project, cost_cents)
      end

      agent_run.log!("metric", {
        tokens_input: tokens_input,
        tokens_output: tokens_output,
        cost_cents: cost_cents,
        llm_model: llm_model,
        request_type: request_type
      }.to_json, metadata: { type: "token_usage" })
    end
  end

  # Evaluates the agent run's cumulative token usage against project limits
  # and updates the token_limit_status field. Logs warnings at the soft
  # threshold and records "exceeded" at the hard limit.
  def self.check_token_limits(agent_run)
    hard_limit = agent_run.effective_max_tokens_per_run
    warning_threshold = agent_run.project.token_limit_warning_threshold
    warning_at = (hard_limit * warning_threshold / 100.0).floor
    current_tokens = agent_run.total_tokens

    new_status = if current_tokens >= hard_limit
      "exceeded"
    elsif current_tokens >= warning_at
      "warning"
    else
      "ok"
    end

    previous_status = agent_run.token_limit_status

    return if new_status == previous_status

    agent_run.update_column(:token_limit_status, new_status)

    if new_status == "warning" && previous_status != "warning"
      agent_run.log!(
        "system",
        "Token usage warning: #{current_tokens} of #{hard_limit} tokens used " \
        "(#{(current_tokens * 100.0 / hard_limit).round(1)}%). " \
        "Run will be stopped at #{hard_limit} tokens.",
        metadata: { type: "token_limit_warning" }
      )
      Rails.logger.warn(
        message: "agent_execution.token_limit_warning",
        agent_run_id: agent_run.id,
        current_tokens: current_tokens,
        hard_limit: hard_limit,
        usage_percent: (current_tokens * 100.0 / hard_limit).round(1)
      )
    elsif new_status == "exceeded"
      agent_run.log!(
        "system",
        "Token limit exceeded: #{current_tokens} of #{hard_limit} tokens used. " \
        "Agent will be stopped after the current operation completes.",
        metadata: { type: "token_limit_exceeded" }
      )
      Rails.logger.warn(
        message: "agent_execution.token_limit_exceeded",
        agent_run_id: agent_run.id,
        current_tokens: current_tokens,
        hard_limit: hard_limit
      )
    end
  end
  private_class_method :check_token_limits

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

  def self.record_per_request_usage(agent_run:, input_tokens:, output_tokens:, cost_cents:, llm_model:, request_type:, metadata:)
    TokenUsage.create!(
      agent_run: agent_run,
      input_tokens: input_tokens,
      output_tokens: output_tokens,
      cost_cents: cost_cents,
      llm_model: llm_model,
      request_type: request_type,
      metadata: metadata
    )
  end
  private_class_method :record_per_request_usage

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
end
