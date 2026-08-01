# frozen_string_literal: true

module HealthChecks
  module Checks
    module User
      class NoAgentRunners < HealthChecks::Check
        self.scope = :user

        def self.network? = false

        def call
          return [] if executable_agent_run_runners.exists?

          finding(
            severity: :error,
            message: "Effective owner has no enabled runners for agent runs."
          )
        end

        private

        def executable_agent_run_runners
          owner&.runners&.kept_only&.for_agent_runs
            &.where(runner_key: RunnerSupport.container_executable_runner_keys) || Runner.none
        end

        def owner
          subject.is_a?(::Project) ? subject.effective_owner : subject
        end
      end
    end
  end
end
