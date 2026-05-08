# frozen_string_literal: true

module StrategyExperiments
  class Create
    attr_reader :name, :strategy_name, :control_config, :variant_configs, :description, :account, :options

    def initialize(name:, strategy_name:, control_config:, variant_configs:, account:, description: nil, **options)
      @name = name
      @strategy_name = strategy_name
      @control_config = control_config
      @variant_configs = variant_configs
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
        experiment = StrategyExperiment.create!(
          account: account,
          name: name,
          description: description,
          strategy_name: strategy_name,
          status: "draft",
          control_config: encoded(control_config),
          min_samples_per_variant: options.fetch(:min_samples_per_variant, 30),
          confidence_threshold: options.fetch(:confidence_threshold, 0.95),
          traffic_percentage: options.fetch(:traffic_percentage, 100)
        )

        experiment.strategy_experiment_variants.create!(
          strategy_config: encoded(control_config),
          is_control: true
        )

        variant_configs.each do |config|
          experiment.strategy_experiment_variants.create!(
            strategy_config: encoded(config),
            is_control: false
          )
        end

        experiment
      end
    end

    private

    def validate!
      raise ArgumentError, "at least one variant config is required" if variant_configs.empty?
      raise ArgumentError, "maximum #{StrategyExperiment::MAX_VARIANTS} variants allowed" if variant_configs.size > StrategyExperiment::MAX_VARIANTS
      raise ArgumentError, "variant configs must be unique" if variant_configs.map { |c| encoded(c) }.uniq.size != variant_configs.size
      raise ArgumentError, "variant configs cannot include the control config" if variant_configs.map { |c| encoded(c) }.include?(encoded(control_config))
      raise ArgumentError, "strategy already has a running experiment" if running_experiment_exists?
    end

    def running_experiment_exists?
      StrategyExperiment.running.exists?(strategy_name: strategy_name, account: account)
    end

    def encoded(value)
      JSON.generate(value)
    end
  end
end
