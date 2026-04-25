# frozen_string_literal: true

module ConfigurationExperiments
  class Create
    attr_reader :name, :config_key, :control_value, :variant_values, :experiment_type, :description, :account, :options

    def initialize(name:, config_key:, control_value:, variant_values:, experiment_type:, description: nil, account: nil, **options)
      @name = name
      @config_key = config_key
      @control_value = control_value
      @variant_values = variant_values
      @experiment_type = experiment_type
      @description = description
      @account = account
      @options = options
    end

    def self.call(...)
      new(...).create
    end

    def create
      validate!

      ActiveRecord::Base.transaction do
        experiment = ConfigurationExperiment.create!(
          account: account,
          name: name,
          description: description,
          config_key: config_key,
          status: "draft",
          control_value: encoded(control_value),
          experiment_type: experiment_type,
          min_samples_per_variant: options.fetch(:min_samples_per_variant, 30),
          confidence_threshold: options.fetch(:confidence_threshold, 0.95),
          traffic_percentage: options.fetch(:traffic_percentage, 100)
        )

        experiment.configuration_experiment_variants.create!(
          config_value: encoded(control_value),
          is_control: true
        )

        variant_values.each do |value|
          experiment.configuration_experiment_variants.create!(
            config_value: encoded(value),
            is_control: false
          )
        end

        experiment
      end
    end

    private

    def validate!
      raise ArgumentError, "at least one variant value is required" if variant_values.empty?
      raise ArgumentError, "maximum #{ConfigurationExperiment::MAX_VARIANTS} variants allowed" if variant_values.size > ConfigurationExperiment::MAX_VARIANTS
      raise ArgumentError, "variant values must be unique" if variant_values.map { |value| encoded(value) }.uniq.size != variant_values.size
      raise ArgumentError, "variant values cannot include the control value" if variant_values.map { |value| encoded(value) }.include?(encoded(control_value))
      raise ArgumentError, "config key already has a running configuration experiment" if running_experiment_exists?
    end

    def running_experiment_exists?
      ConfigurationExperiment.running.exists?(config_key: config_key, account: account)
    end

    def encoded(value)
      JSON.generate(value)
    end
  end
end
