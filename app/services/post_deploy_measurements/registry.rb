# frozen_string_literal: true

module PostDeployMeasurements
  # The reviewed allowlist of trusted post-deploy checks. Entries exist only
  # in code: there is no operator-supplied SQL, command, or configuration
  # path that can introduce or mutate a check without review. Evidence is
  # only current for the registry's own check version; a superseded version
  # must be re-requested, never reused.
  # @spec POST-DEPLOY-001
  module Registry
    class UnknownCheck < StandardError; end

    CHECKS = [
      Checks::PlanningHoldNotifications::CHECK
    ].freeze

    def self.all = CHECKS

    def self.find(key) = all.find { |check| check.key == key.to_s }

    def self.find!(key)
      find(key) or raise UnknownCheck, "Post-deploy check #{key.inspect} is not allowlisted; only reviewed registry checks can run."
    end
  end
end
