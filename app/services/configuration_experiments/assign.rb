# frozen_string_literal: true

module ConfigurationExperiments
  class Assign
    attr_reader :configuration_experiment, :agent_run, :variant

    def initialize(configuration_experiment:, agent_run:, variant: nil)
      @configuration_experiment = configuration_experiment
      @agent_run = agent_run
      @variant = variant
    end

    def self.call(...)
      new(...).assign
    end

    def assign
      raise ArgumentError, "configuration experiment is not running" unless configuration_experiment.running?

      existing = ConfigurationExperimentAssignment.find_by(
        configuration_experiment: configuration_experiment,
        agent_run: agent_run
      )
      if existing
        return existing unless variant.present?

        selected_variant = validate_variant!(variant)
        return existing if existing.configuration_experiment_variant_id == selected_variant.id

        existing.update!(configuration_experiment_variant: selected_variant)
        return existing
      end

      variant = select_variant

      begin
        ConfigurationExperimentAssignment.create!(
          configuration_experiment: configuration_experiment,
          configuration_experiment_variant: variant,
          agent_run: agent_run
        )
      rescue ActiveRecord::RecordNotUnique
        ConfigurationExperimentAssignment.find_by!(
          configuration_experiment: configuration_experiment,
          agent_run: agent_run
        )
      end
    end

    private

    def select_variant
      return validate_variant!(variant) if variant.present?

      variants = configuration_experiment.configuration_experiment_variants.order(:id).to_a
      raise ArgumentError, "configuration experiment has no variants" if variants.empty?
      return variants.first if variants.size == 1

      assignment_counts = ConfigurationExperimentAssignment
        .where(configuration_experiment: configuration_experiment, configuration_experiment_variant: variants)
        .group(:configuration_experiment_variant_id)
        .count
      max_count = variants.map { |variant| assignment_counts[variant.id] || 0 }.max
      weights = variants.map { |variant| (max_count - (assignment_counts[variant.id] || 0)) + 1 }
      total = weights.sum.to_f

      roll = rand
      cumulative = 0.0

      variants.zip(weights).each do |variant, weight|
        cumulative += weight / total
        return variant if roll < cumulative
      end

      variants.last
    end

    def validate_variant!(candidate)
      return candidate if candidate.configuration_experiment_id == configuration_experiment.id

      raise ArgumentError, "configuration experiment variant must belong to the same experiment"
    end
  end
end
