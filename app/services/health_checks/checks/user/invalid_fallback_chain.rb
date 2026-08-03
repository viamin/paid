# frozen_string_literal: true

module HealthChecks
  module Checks
    module User
      class InvalidFallbackChain < HealthChecks::Check
        self.scope = :user

        def self.network? = false

        def call
          return [] unless setting

          stale = setting.stale_fallback_runner_tokens
          return [] if stale.empty?

          finding(
            severity: :warning,
            title: "Fallback runner chain references unavailable runners",
            description: "These fallback runners are disabled or no longer present: #{stale.join(', ')}.",
            remediation: "Remove or replace the unavailable runners in the fallback chain.",
            action_url: collection_action_url(:runners_path),
            metadata: { stale_fallback_runners: stale }
          )
        end

        private

        def setting
          @setting ||= subject.user_setting
        end
      end
    end
  end
end
