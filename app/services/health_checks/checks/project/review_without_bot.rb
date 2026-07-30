# frozen_string_literal: true

module HealthChecks
  module Checks
    module Project
      class ReviewWithoutBot < HealthChecks::Check
        self.scope = :project

        def self.network? = false

        def call
          return [] unless auto_review.enabled?
          return [] unless auto_review.method_enabled?(:paid_agent)
          return [] if Github::ReviewBotInstallationToken.configured?

          finding(
            severity: :error,
            message: "Paid Agent review is enabled but the paid-code-reviewer GitHub App is not configured."
          )
        end

        private

        def auto_review
          @auto_review ||= Automation::Configuration::Project.from(subject).auto_review
        end
      end
    end
  end
end
