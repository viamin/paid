# frozen_string_literal: true

class TokenUsageTracker
  # Default pricing per million tokens (Claude 3.5 Sonnet)
  DEFAULT_INPUT_COST_PER_MILLION = BigDecimal("3.00")
  DEFAULT_OUTPUT_COST_PER_MILLION = BigDecimal("15.00")

  def self.track(agent_run:, tokens_input:, tokens_output:, model_name: nil, request_type: "agent", metadata: {})
    cost_cents = calculate_cost(tokens_input, tokens_output)

    record_per_request_usage(
      agent_run: agent_run,
      input_tokens: tokens_input,
      output_tokens: tokens_output,
      cost_cents: cost_cents,
      model_name: model_name,
      request_type: request_type,
      metadata: metadata
    )

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

    agent_run.log!("metric", {
      tokens_input: tokens_input,
      tokens_output: tokens_output,
      cost_cents: cost_cents,
      model_name: model_name,
      request_type: request_type
    }.to_json, metadata: { type: "token_usage" })
  end

  def self.calculate_cost(input_tokens, output_tokens)
    input_cost = BigDecimal(input_tokens.to_s) / BigDecimal("1000000") * DEFAULT_INPUT_COST_PER_MILLION
    output_cost = BigDecimal(output_tokens.to_s) / BigDecimal("1000000") * DEFAULT_OUTPUT_COST_PER_MILLION
    ((input_cost + output_cost) * 100).round.to_i
  end

  def self.record_per_request_usage(agent_run:, input_tokens:, output_tokens:, cost_cents:, model_name:, request_type:, metadata:)
    TokenUsage.create!(
      agent_run: agent_run,
      input_tokens: input_tokens,
      output_tokens: output_tokens,
      cost_cents: cost_cents,
      model_name: model_name,
      request_type: request_type,
      metadata: metadata
    )
  rescue ActiveRecord::RecordInvalid => e
    Rails.logger.error(
      message: "token_usage_tracker.record_failed",
      agent_run_id: agent_run.id,
      error: e.message
    )
  end
  private_class_method :record_per_request_usage

  def self.update_cost_budgets(project, cost_cents)
    project.cost_budgets.find_each do |budget|
      budget.record_usage!(cost_cents)
    end
  rescue => e
    Rails.logger.error(
      message: "token_usage_tracker.budget_update_failed",
      project_id: project.id,
      error: e.message
    )
  end
  private_class_method :update_cost_budgets
end
