# frozen_string_literal: true

module Automation
  # RDR-077 Rollout Guard: the phase model is default-off and every decision
  # reads it through the project's feature-flag value. While off, the
  # pre-existing execution and Inbox policies stay in force.
  #
  # @spec AUTOMATION-PHASES-014
  module RolloutGuard
    FLAG = :automation_phases

    module_function

    def enabled?(project)
      FeatureFlags.enabled?(FLAG, project:)
    end

    # Flag state for every project in a scope, without N+1 flag reads when a
    # caller already has the projects in memory.
    def enabled_for?(project)
      return false unless project

      enabled?(project)
    end
  end
end
