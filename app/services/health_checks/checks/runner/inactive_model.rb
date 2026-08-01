# frozen_string_literal: true

module HealthChecks
  module Checks
    module Runner
      class InactiveModel < HealthChecks::Check
        include ModelCheckSupport

        self.scope = :runner

        def self.network? = false

        def call
          LlmModel::TIERS.filter_map do |tier|
            model = resolved_tier_model(tier)
            next unless model
            next if model.active?

            build_finding(
              severity: :error,
              message: "Runner #{subject.display_name} resolves inactive model #{model.model_id} for #{tier} tier."
            )
          end
        end
      end
    end
  end
end
