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
            title: "Review enabled without the review bot configured",
            description: "Paid Agent review is enabled but the paid-code-reviewer GitHub App is not configured.",
            remediation: "Configure the paid-code-reviewer GitHub App credentials or disable the Paid Agent review method.",
            action_url: settings_action_url(:edit_project_path, anchor: "review-settings")
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
