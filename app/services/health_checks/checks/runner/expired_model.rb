# frozen_string_literal: true

module HealthChecks
  module Checks
    module Runner
      class ExpiredModel < HealthChecks::Check
        include ModelCheckSupport

        self.scope = :runner

        def self.network? = false

        def call
          LlmModel::TIERS.filter_map do |tier|
            model = resolved_tier_model(tier)
            next unless model&.expired?

            build_finding(
              severity: :warning,
              message: "Runner #{subject.display_name} resolves expired model #{model.model_id} for #{tier} tier."
            )
          end
        end
      end
    end
  end
end
