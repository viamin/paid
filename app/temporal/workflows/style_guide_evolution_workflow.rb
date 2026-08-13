# frozen_string_literal: true

module Workflows
  class StyleGuideEvolutionWorkflow < BaseWorkflow
    AB_TEST_TIMEOUT = 30

    # @spec STYLE-GUIDE-EVOLUTION-010
    def execute(input)
      style_guide_id = input[:style_guide_id]
      project_id = input[:project_id]

      sample_result = run_activity(
        Activities::SampleStyleGuideRunsActivity,
        {
          style_guide_id: style_guide_id,
          project_id: project_id,
          sample_size: input.fetch(:sample_size, StyleGuideEvolution::SampleRuns::DEFAULT_SAMPLE_SIZE),
          sample_days: input.fetch(:sample_days, StyleGuideEvolution::SampleRuns::DEFAULT_DAYS),
          threshold: input.fetch(:threshold, StyleGuideEvolution::SampleRuns::QUALITY_THRESHOLD)
        },
        timeout: 60
      )

      candidates = sample_result[:evolution_candidates]
      return { status: :no_candidates, style_guide_id: style_guide_id } if candidates.blank?

      mutation_result = run_activity(
        Activities::GenerateStyleGuideMutationsActivity,
        {
          style_guide_id: style_guide_id,
          quality_metrics: sample_result[:quality_metrics],
          mutation_count: input.fetch(:mutation_count, 3),
          strategies: input[:strategies]
        },
        timeout: LLM_ACTIVITY_TIMEOUT,
        heartbeat_timeout: DEFAULT_HEARTBEAT_TIMEOUT
      )
      mutations = mutation_result[:mutations]
      return { status: :no_mutations, style_guide_id: style_guide_id } if mutations.blank?

      variants_result = run_activity(
        Activities::CreateStyleGuideVariantsActivity,
        {
          style_guide_id: style_guide_id,
          mutations: mutations
        },
        timeout: 30
      )
      variant_version_ids = variants_result[:variant_version_ids]
      return { status: :no_variants_created, style_guide_id: style_guide_id } if variant_version_ids.blank?

      ab_test_result = run_activity(
        Activities::CreateStyleGuideAbTestActivity,
        {
          style_guide_id: style_guide_id,
          variant_version_ids: variant_version_ids,
          min_samples_per_variant: input.fetch(:min_samples, 30),
          confidence_threshold: input.fetch(:confidence, 0.95)
        },
        timeout: AB_TEST_TIMEOUT
      )

      {
        status: :evolution_started,
        style_guide_id: style_guide_id,
        style_guide_ab_test_id: ab_test_result[:style_guide_ab_test_id],
        variant_count: variant_version_ids.size
      }
    end
  end
end
