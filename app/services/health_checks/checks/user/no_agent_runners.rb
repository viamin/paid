# frozen_string_literal: true

module HealthChecks
  module Checks
    module User
      class NoAgentRunners < HealthChecks::Check
        self.scope = :user

        def self.network? = false

        def call
          return [] if owner&.runners&.kept_only&.for_agent_runs&.exists?

          finding(
            severity: :error,
            message: "Effective owner has no enabled runners for agent runs."
          )
        end

        private

        def owner
          subject.is_a?(::Project) ? subject.effective_owner : subject
        end
      end
    end
  end
end
