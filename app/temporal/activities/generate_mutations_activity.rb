# frozen_string_literal: true

module Activities
  # Generates improved prompt variants by calling PromptEvolution::Mutate,
  # which uses an LLM to analyze performance data and propose targeted
  # mutations.
  #
  # Returns serializable mutation data (templates, strategies, reasoning)
  # for the workflow to pass to CreateEvolutionVariantsActivity.
  class GenerateMutationsActivity < BaseActivity
    activity_name "GenerateMutations"

    def execute(input)
      prompt_id = input[:prompt_id]
      mutation_count = input.fetch(:mutation_count, 3)
      strategies = input[:strategies]
      quality_metrics_data = input.fetch(:quality_metrics, [])
      sample_outputs = input.fetch(:sample_outputs, {})

      prompt = Prompt.find(prompt_id)

      quality_metrics = build_quality_metrics(quality_metrics_data)

      options = { mutation_count: mutation_count }
      options[:strategies] = strategies if strategies.present?

      mutations = with_periodic_heartbeat("generate_mutations", prompt_id: prompt_id, mutation_count: mutation_count) do
        PromptEvolution::Mutate.call(
          prompt: prompt,
          quality_metrics: quality_metrics,
          sample_outputs: sample_outputs,
          options: options
        )
      end

      {
        prompt_id: prompt_id,
        mutations: serialize_mutations(mutations)
      }
    end

    private

    MetricProxy = Struct.new(:composite_score, :scores, keyword_init: true)

    def build_quality_metrics(data)
      Array(data).map do |qm|
        MetricProxy.new(
          composite_score: qm[:composite_score],
          scores: qm[:scores]
        )
      end
    end

    def serialize_mutations(mutations)
      mutations.map do |m|
        {
          template: m.template,
          strategy: m.strategy,
          reasoning: m.reasoning,
          expected_improvement: m.expected_improvement
        }
      end
    end
  end
end
