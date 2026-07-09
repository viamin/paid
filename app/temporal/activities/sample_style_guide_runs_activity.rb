# frozen_string_literal: true

module Activities
  class SampleStyleGuideRunsActivity < BaseActivity
    activity_name "SampleStyleGuideRuns"

    def execute(input)
      result = StyleGuideEvolution::SampleRuns.call(
        style_guide_id: input[:style_guide_id],
        project_id: input[:project_id],
        sample_size: input.fetch(:sample_size, StyleGuideEvolution::SampleRuns::DEFAULT_SAMPLE_SIZE),
        days: input.fetch(:sample_days, StyleGuideEvolution::SampleRuns::DEFAULT_DAYS),
        threshold: input.fetch(:threshold, StyleGuideEvolution::SampleRuns::QUALITY_THRESHOLD)
      )

      {
        evolution_candidates: result.evolution_candidates.map do |candidate|
          {
            style_guide_version_id: candidate[:style_guide_version].id,
            avg_score: candidate[:avg_score],
            run_count: candidate[:run_count],
            reasons: candidate[:reasons]
          }
        end,
        quality_metrics: result.samples.map { |sample| { composite_score: sample[:composite_score], scores: sample[:scores] } }
      }
    end
  end
end
