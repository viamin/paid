# frozen_string_literal: true

class TokenUsageTracker
  # Default pricing per million tokens (Claude Sonnet 4.6 fallback)
  DEFAULT_INPUT_COST_PER_MILLION = BigDecimal("3.00")
  DEFAULT_OUTPUT_COST_PER_MILLION = BigDecimal("15.00")

  def self.track(agent_run:, tokens_input:, tokens_output:, model_id: nil)
    # Use the already-loaded llm_model from the agent run's model selection
    # to avoid a redundant LlmModel.find_by query in calculate_cost.
    llm_model = agent_run.model_selection&.llm_model
    model_id ||= llm_model&.model_id
    cost_cents = calculate_cost(tokens_input, tokens_output, llm_model: llm_model, model_id: model_id)

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
      cost_cents: cost_cents,
      model_id: model_id
    }.to_json, metadata: { type: "token_usage" })
  end

  def self.calculate_cost(input_tokens, output_tokens, llm_model: nil, model_id: nil)
    model = llm_model || (LlmModel.find_by(model_id: model_id) if model_id.present?)

    if model&.input_cost_per_million && model&.output_cost_per_million
      model.estimated_cost(input_tokens, output_tokens)
    else
      input_cost = BigDecimal(input_tokens.to_s) / BigDecimal("1000000") * DEFAULT_INPUT_COST_PER_MILLION
      output_cost = BigDecimal(output_tokens.to_s) / BigDecimal("1000000") * DEFAULT_OUTPUT_COST_PER_MILLION
      ((input_cost + output_cost) * 100).round.to_i
    end
  end
end
