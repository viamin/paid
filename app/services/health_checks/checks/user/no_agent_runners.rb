# frozen_string_literal: true

module HealthChecks
  module Checks
    module User
      class NoAgentRunners < HealthChecks::Check
        self.scope = :user

        def self.network? = false

        def call
          return [] if subject.runners.kept_only.for_agent_runs.any?

          finding(
            severity: :error,
            title: "No runners enabled for agent runs",
            description: "The project owner has no runners enabled for agent runs, so no agent work can be dispatched.",
            remediation: "Enable at least one runner for agent runs.",
            action_url: collection_action_url(:runners_path)
          )
        end
      end
    end
  end
end
