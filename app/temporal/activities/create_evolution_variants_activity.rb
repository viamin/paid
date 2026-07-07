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
        project: project,
        idempotency_key: idempotency_key_for(prompt_id, mutations_data)
      )

      {
        prompt_id: prompt_id,
        variant_version_ids: variants.map(&:id),
        variant_count: variants.size,
        review_required: prompt.requires_review?
      }
    end

    private

    # Stable across Temporal retries: derived from the prompt id and the
    # exact mutation payloads Temporal replays, so a retry reuses the
    # PromptVersions a previous attempt already created (#2770).
    def idempotency_key_for(prompt_id, mutations_data)
      Activities::IdempotencyKey.compute(prompt_id, mutations_data)
    end
  end
end
