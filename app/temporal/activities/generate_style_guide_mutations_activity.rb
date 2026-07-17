# frozen_string_literal: true

module Activities
  class GenerateStyleGuideMutationsActivity < BaseActivity
    activity_name "GenerateStyleGuideMutations"

    def execute(input)
      style_guide = StyleGuide.find(input[:style_guide_id])
      mutations = StyleGuideEvolution::Mutate.call(
        style_guide: style_guide,
        quality_metrics: input.fetch(:quality_metrics, []),
        sample_outputs: {},
        options: {
          mutation_count: input.fetch(:mutation_count, 3),
          strategies: input[:strategies]
        }
      )

      {
        mutations: mutations.map do |mutation|
          {
            raw_content: mutation.raw_content,
            strategy: mutation.strategy,
            reasoning: mutation.reasoning,
            expected_improvement: mutation.expected_improvement
          }
        end
      }
    end
  end
end
