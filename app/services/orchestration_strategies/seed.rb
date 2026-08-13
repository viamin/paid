# frozen_string_literal: true

module OrchestrationStrategies
  # Idempotently creates system-default OrchestrationStrategy records from
  # hardcoded defaults. Safe to run in migrations, seeds, or rake tasks.
  #
  # Existing active records are left untouched — only missing strategy
  # types are inserted.
  class Seed
    def self.call
      new.call
    end

    def call
      created = []

      OrchestrationStrategy::STRATEGY_TYPES.each do |strategy_type|
        next if OrchestrationStrategy.system_defaults.by_type(strategy_type).active.exists?

        config = Defaults.configuration_for(strategy_type)
        next unless config

        record = OrchestrationStrategy.create!(
          account: nil,
          strategy_type: strategy_type,
          name: default_name_for(strategy_type),
          version: 1,
          configuration: config,
          active: true
        )
        created << record
      end

      created
    end

    private

    def default_name_for(strategy_type)
      strategy_type.titleize
    end
  end
end
