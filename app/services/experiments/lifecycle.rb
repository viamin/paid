# frozen_string_literal: true

module Experiments
  # Shared auto-completion loop used by every experiment framework's
  # `RecordResult` path. Reads cached analysis when samples have accumulated
  # to a multiple of the analysis interval, then transitions the experiment
  # to completed when a winner / control-wins outcome emerges.
  #
  # The host experiment model must expose:
  #   * `running?`, `sufficient_samples?`
  #   * `min_samples_per_variant`
  #   * `cached_or_compute_analysis` (provided by Experiments::AnalysisCache
  #     for analyzers using the standard Welch's t-test cache)
  #   * `complete!(winner:)` for completion
  #   * `<variants_association>` whose records respond to `sample_count`
  module Lifecycle
    module_function

    # @param experiment [ApplicationRecord]
    # @param score_recorded [Boolean] whether a new score was recorded
    # @param analysis_interval [Integer] throttle for the compute cost of analysis
    # @param force_analysis [Boolean] run analysis even when not at the interval
    #   (used by `update_existing: true` record paths)
    # @param on_complete [Proc, nil] optional hook invoked after a successful
    #   completion transition. Receives the freshly-completed experiment as
    #   its argument. Used by frameworks that promote winners or perform
    #   additional side-effects on completion.
    def maybe_complete(experiment, score_recorded:, analysis_interval:, force_analysis: false, on_complete: nil)
      return unless score_recorded

      experiment.reload
      return unless experiment.running?
      return unless experiment.sufficient_samples?
      return unless force_analysis || should_analyze?(experiment, analysis_interval:)

      result = experiment.cached_or_compute_analysis
      return if result.nil? || result.status == :insufficient_data

      completed = false
      if result.status == :winner_found
        experiment.complete!(winner: result.winner)
        completed = true
      elsif result.status == :control_wins
        experiment.complete!
        completed = true
      end

      on_complete.call(experiment) if completed && on_complete
    rescue ActiveRecord::RecordInvalid
      # Another process already completed or cancelled the experiment
      # concurrently. Treat as a no-op.
      nil
    end

    def should_analyze?(experiment, analysis_interval:)
      sample_counts = experiment.public_send(experiment.class.variants_association).pluck(:sample_count)
      total = sample_counts.sum
      variants_count = sample_counts.count
      min_required = experiment.min_samples_per_variant * variants_count
      total == min_required || (total % analysis_interval).zero?
    end
  end
end
