# frozen_string_literal: true

module Activities
  # Samples recently completed agent runs with quality metrics and identifies
  # underperforming prompts as evolution candidates.
  #
  # Wraps PromptEvolution::SampleRuns and reshapes its output for workflow
  # consumption, including extracting sample outputs for the mutation step.
  class SampleRunsActivity < BaseActivity
    activity_name "SampleRuns"

    MAX_SAMPLE_OUTPUTS = 3
    MAX_OUTPUT_LENGTH = 2_000

    def execute(input)
      prompt_id = input[:prompt_id]
      project_id = input[:project_id]
      sample_size = input.fetch(:sample_size, 50)
      sample_days = input.fetch(:sample_days, 14)

      prompt = Prompt.find(prompt_id)

      result = PromptEvolution::SampleRuns.call(
        sample_size: sample_size,
        days: sample_days,
        project_id: project_id
      )

      # Filter candidates to only those for this prompt
      candidates = result.evolution_candidates.select do |c|
        c[:prompt_version]&.prompt_id == prompt.id
      end

      # Extract sample outputs for the mutation activity
      prompt_samples = result.samples.select do |s|
        s[:prompt_version]&.prompt_id == prompt.id
      end

      sample_outputs = extract_sample_outputs(prompt_samples)
      quality_metrics = extract_quality_metrics(prompt_samples)

      # Serialize prompt stats (only for this prompt's versions)
      prompt_stats = result.prompt_stats.select do |version_id, stats|
        stats[:prompt_version]&.prompt_id == prompt.id
      end.transform_values do |stats|
        stats.except(:prompt_version)
      end

      {
        prompt_id: prompt_id,
        evolution_candidates: serialize_candidates(candidates),
        prompt_stats: prompt_stats,
        sample_outputs: sample_outputs,
        quality_metrics: quality_metrics,
        total_samples: result.samples.size
      }
    end

    private

    def extract_sample_outputs(samples)
      sorted = samples.sort_by { |s| s[:composite_score] || 0 }
      failures = sorted.first(MAX_SAMPLE_OUTPUTS).filter_map do |s|
        next unless s[:composite_score] && s[:composite_score] < PromptEvolution::SampleRuns::QUALITY_THRESHOLD

        summarize_run(s)
      end

      successes = sorted.reverse.first(MAX_SAMPLE_OUTPUTS).filter_map do |s|
        next unless s[:composite_score] && s[:composite_score] >= PromptEvolution::SampleRuns::QUALITY_THRESHOLD

        summarize_run(s)
      end

      { successes: successes, failures: failures }
    end

    def summarize_run(sample)
      run = sample[:agent_run]
      parts = []
      parts << "Goal: #{run.goal}" if run.goal.present?
      parts << "Score: #{sample[:composite_score]&.round(4)}"
      parts << "Cost: #{sample[:cost_cents]}c" if sample[:cost_cents]
      parts << "Duration: #{sample[:duration_seconds]}s" if sample[:duration_seconds]
      parts.join(", ").truncate(MAX_OUTPUT_LENGTH)
    end

    def extract_quality_metrics(samples)
      samples.filter_map do |s|
        score = s[:composite_score]
        next unless score

        { composite_score: score }
      end
    end

    def serialize_candidates(candidates)
      candidates.map do |c|
        {
          prompt_version_id: c[:prompt_version]&.id,
          avg_score: c[:avg_score],
          run_count: c[:run_count],
          reasons: c[:reasons]
        }
      end
    end
  end
end
