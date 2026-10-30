# frozen_string_literal: true

module Projects
  class ScalingDashboardStats
    RECENT_OBSERVATION_LIMIT = 15
    REPORT_NOTE_REPLACEMENTS = {
      "Scaling exponent confidence uses a log-log linear fit instead of the full regression suite proposed in the RDR." =>
        "Scaling exponent confidence uses a log-log linear fit instead of comparing power-law, logarithmic, and linear models.",
      "The dashboard flags experiments configured below the 30-sample RDR target instead of enforcing that threshold retroactively." =>
        "The dashboard flags experiments configured below the 30-sample target instead of enforcing that threshold retroactively.",
      "Uses descriptive confidence intervals rather than the full comparative regression suite proposed in the RDR." =>
        "Uses descriptive confidence intervals rather than comparing power-law, logarithmic, and linear regression models.",
      "Treats configured experiment sample floors below 30 as intentional simplifications and flags them in reporting." =>
        "Treats experiments configured below 30 samples per value as limited evidence and flags them in reporting."
    }.freeze

    attr_reader :project

    def initialize(project:)
      @project = project
    end

    def self.call(...)
      new(...).call
    end

    def call
      {
        summary: summary,
        recommendations: recommendations,
        experiments: experiments,
        recent_observations: recent_observations,
        sparse: sparse?
      }
    end

    private

    def summary
      {
        experiment_count: scaling_experiments.count,
        active_experiment_count: scaling_experiments.count(&:running?),
        completed_experiment_count: scaling_experiments.count { |experiment| experiment.status == "completed" },
        observation_count: scaling_observations.count,
        ready_recommendation_count: recommendations.count,
        actionable_recommendation_count: recommendations.count { |row| row[:actionable] },
        rdr_ready_experiment_count: experiments.count { |row| row.dig(:sample_threshold_review, "meets_rdr_target") }
      }
    end

    def recommendations
      @recommendations ||= experiments.filter_map do |row|
        decision = row[:recommendation]
        next unless decision.is_a?(Hash)

        {
          experiment: row[:experiment],
          dimension: row[:dimension],
          recommended_value: decision["recommended_value"],
          confidence: decision["confidence"],
          actionable: decision["actionable"],
          sample_count: decision["sample_count"],
          reason: decision["reason"],
          efficiency_gain_vs_control: decision["efficiency_gain_vs_control"],
          scaling_exponent: decision["scaling_exponent"],
          scaling_exponent_confidence_interval: decision["scaling_exponent_confidence_interval"],
          sample_threshold_review: row[:sample_threshold_review]
        }
      end
    end

    def experiments
      @experiments ||= scaling_experiments.map do |experiment|
        summary = experiment.cached_or_compute_summary(persist: false) || {}
        scaling_law = summary.fetch("scaling_law", {})
        recommendation = recommendation_for(summary:, scaling_law:)

        {
          experiment: experiment,
          dimension: experiment.dimension,
          summary: summary,
          values: Array(summary["values"]),
          recommendation: recommendation,
          primary_metric: summary["primary_metric"],
          sample_threshold_review: summary["sample_threshold_review"] || scaling_law["sample_threshold_review"] || {},
          statistical_rigor: scaling_law["statistical_rigor"] || {},
          simplifications: user_facing_simplifications(summary:, scaling_law:),
          leading_value: summary["leading_value"],
          recommendation_ready: recommendation.present?,
          actionable: recommendation&.fetch("actionable", false)
        }
      end
    end

    def recent_observations
      scaling_observations.limit(RECENT_OBSERVATION_LIMIT).to_a
    end

    def sparse?
      summary[:experiment_count].zero? && summary[:observation_count].zero?
    end

    def scaling_experiments
      @scaling_experiments ||= ScalingExperiment
        .where(project: project)
        .includes(:scaling_experiment_assignments)
        .order(created_at: :desc)
        .to_a
    end

    def scaling_observations
      @scaling_observations ||= ScalingObservation
        .where(project: project)
        .order(created_at: :desc, id: :desc)
    end

    def recommendation_for(summary:, scaling_law:)
      summary["allocator_decision"] || scaling_law["allocator_decision"]
    end

    def user_facing_simplifications(summary:, scaling_law:) # @spec SCALING-EXPERIMENTS-002
      notes = Array(summary["simplifications"]).presence || Array(scaling_law.dig("statistical_rigor", "simplifications"))
      notes.map { |note| REPORT_NOTE_REPLACEMENTS.fetch(note, note) }
    end
  end
end
