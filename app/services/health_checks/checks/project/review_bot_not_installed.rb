# frozen_string_literal: true

module HealthChecks
  module Checks
    module Project
      class ReviewBotNotInstalled < HealthChecks::Check
        self.scope = :project

        def self.network? = true

        def call
          return [] unless review_bot_enabled?
          return [] unless Github::ReviewBotInstallationToken.configured?

          review_bot_token.installation_id
          []
        rescue Github::ReviewBotInstallationToken::NotInstalledError
          finding(
            severity: :warning,
            message: "Paid Agent review is enabled but the paid-code-reviewer GitHub App is not installed on this repository."
          )
        rescue Github::ReviewBotInstallationToken::Error
          []
        end

        private

        def review_bot_enabled?
          subject.review_enabled? && subject.review_method_enabled?(:paid_agent)
        end

        def review_bot_token
          @review_bot_token ||= Github::ReviewBotInstallationToken.new(repo_full_name: subject.full_name)
        end
      end
    end
  end
end
