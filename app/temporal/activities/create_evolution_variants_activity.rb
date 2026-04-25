# frozen_string_literal: true

module Activities
  # Persists LLM-generated mutations as PromptVersion records. Delegates
  # to PromptEvolution::CreateVariants which handles the review gate
  # (auto-promote vs pending review based on prompt configuration).
  class CreateEvolutionVariantsActivity < BaseActivity
    activity_name "CreateEvolutionVariants"

    def execute(input)
      prompt_id = input[:prompt_id]
      project_id = input[:project_id]
      mutations_data = input.fetch(:mutations, [])

      prompt = Prompt.find(prompt_id)
      project = project_id ? Project.find(project_id) : prompt.project

      mutations = mutations_data.map do |m|
        PromptEvolution::Mutate::Mutation.new(
          template: m[:template],
          strategy: m[:strategy],
          reasoning: m[:reasoning],
          expected_improvement: m[:expected_improvement]
        )
      end

      variants = PromptEvolution::CreateVariants.call(
        prompt: prompt,
        mutations: mutations,
        project: project
      )

      {
        prompt_id: prompt_id,
        variant_version_ids: variants.map(&:id),
        variant_count: variants.size,
        review_required: prompt.requires_review?
      }
    end
  end
end
