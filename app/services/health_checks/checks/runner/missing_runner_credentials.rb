# frozen_string_literal: true

module HealthChecks
  module Checks
    module Runner
      class MissingRunnerCredentials < HealthChecks::Check
        self.scope = :runner

        def self.network? = false

        def call
          return [] unless subject.api_key?
          return [] if subject.effective_api_secret.present?

          finding(
            severity: :error,
            message: "Runner #{subject.display_name} is configured for API key auth but has no usable credentials."
          )
        end
      end
    end
  end
end
