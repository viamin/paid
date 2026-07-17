# frozen_string_literal: true

module Activities
  class SampleStyleGuideRunsActivity < BaseActivity
    activity_name "SampleStyleGuideRuns"

    def execute(input)
      style_guide = StyleGuide.find(input[:style_guide_id])
      result = StyleGuideEvolution::SampleRuns.call(
        style_guide_id: input[:style_guide_id],
        project_id: input[:project_id],
        sample_size: input.fetch(:sample_size, StyleGuideEvolution::SampleRuns::DEFAULT_SAMPLE_SIZE),
        days: input.fetch(:sample_days, StyleGuideEvolution::SampleRuns::DEFAULT_DAYS),
        threshold: input.fetch(:threshold, StyleGuideEvolution::SampleRuns::QUALITY_THRESHOLD)
      )

      # Restrict evolution candidates to the current version only. Historical and
      # A/B test variants that underperform must not retrigger mutation when the
      # current version is healthy — their fate is determined by the A/B test result.
      current_version_id = style_guide.current_version_id
      current_version_candidates = result.evolution_candidates.select do |candidate|
        candidate[:style_guide_version].id == current_version_id
      end

      {
        evolution_candidates: current_version_candidates.map do |candidate|
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
