# frozen_string_literal: true

module HealthChecks
  module Checks
    module User
      class MissingDefaultRunner < HealthChecks::Check
        self.scope = :user

        def self.network? = false

        def call
          return [] unless setting
          return [] unless setting.default_runner_unavailable?

          finding(
            severity: :warning,
            title: "Default runner is no longer available",
            description: %(The default runner is set to "#{setting.default_agent_runner}", which is disabled or no longer present.),
            remediation: "Choose a different default runner.",
            action_url: collection_action_url(:runners_path),
            metadata: { default_agent_runner: setting.default_agent_runner }
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
