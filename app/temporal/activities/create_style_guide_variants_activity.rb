# frozen_string_literal: true

module Activities
  class CreateStyleGuideVariantsActivity < BaseActivity
    activity_name "CreateStyleGuideVariants"

    def execute(input)
      style_guide = StyleGuide.find(input[:style_guide_id])
      mutations = input.fetch(:mutations, []).map do |mutation|
        StyleGuideEvolution::Mutate::Mutation.new(
          raw_content: mutation[:raw_content],
          strategy: mutation[:strategy],
          reasoning: mutation[:reasoning],
          expected_improvement: mutation[:expected_improvement]
        )
      end

      variants = StyleGuideEvolution::CreateVariants.call(
        style_guide: style_guide,
        mutations: mutations,
        idempotency_key: Activities::IdempotencyKey.compute(style_guide.id, input[:mutations])
      )

      {
        variant_version_ids: variants.map(&:id),
        variant_count: variants.size
      }
    end
  end
end
