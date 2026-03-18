# frozen_string_literal: true

class TokenUsageTracker
  # Default pricing per million tokens (Claude 3.5 Sonnet)
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
    cost_cents    = calculate_cost(tokens_input, tokens_output)

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

  def self.calculate_cost(input_tokens, output_tokens)
    input_cost = BigDecimal(input_tokens.to_s) / BigDecimal("1000000") * DEFAULT_INPUT_COST_PER_MILLION
    output_cost = BigDecimal(output_tokens.to_s) / BigDecimal("1000000") * DEFAULT_OUTPUT_COST_PER_MILLION
    ((input_cost + output_cost) * 100).round.to_i
  end

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
