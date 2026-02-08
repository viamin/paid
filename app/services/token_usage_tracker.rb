# frozen_string_literal: true

class TokenUsageTracker
  # Default pricing per million tokens (Claude 3.5 Sonnet)
  DEFAULT_INPUT_COST_PER_MILLION = 3.00
  DEFAULT_OUTPUT_COST_PER_MILLION = 15.00

  def self.track(agent_run:, tokens_input:, tokens_output:)
    cost_cents = calculate_cost(tokens_input, tokens_output)

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

    agent_run.log!("metric", {
      tokens_input: tokens_input,
      tokens_output: tokens_output,
      cost_cents: cost_cents
    }.to_json, metadata: { type: "token_usage" })
  end

  def self.calculate_cost(input_tokens, output_tokens)
    input_cost = (input_tokens / 1_000_000.0) * DEFAULT_INPUT_COST_PER_MILLION
    output_cost = (output_tokens / 1_000_000.0) * DEFAULT_OUTPUT_COST_PER_MILLION
    ((input_cost + output_cost) * 100).round
  end
end
