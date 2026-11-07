# frozen_string_literal: true

module PostDeployMeasurements
  # Probes the tenant-scoped read path each check declares as a required
  # capability. A capability is available only when its bounded read succeeds
  # under the current tenant context with normal database-role rules; an
  # unavailable capability is escalated with a recovery action, never treated
  # as a zero or a pass.
  # @spec POST-DEPLOY-005 @spec POST-DEPLOY-007
  module Capabilities
    UNAVAILABLE = Data.define(:name, :recovery) do
      def unavailable? = true
    end

    class << self
      # Returns nil when every capability is available, else the first
      # unavailable capability with its named recovery action.
      def first_unavailable(capabilities, project:)
        capabilities.each do |name|
          probe = probes[name]
          return UNAVAILABLE.new(name, unknown_capability_recovery(name)) unless probe
          return UNAVAILABLE.new(name, probe[:recovery]) unless send(probe[:probe], project)
        end
        nil
      end

      private

      def unknown_capability_recovery(name)
        "Required capability #{name.inspect} has no probe; request a fresh measurement with the current check version."
      end

      def probes
        {
          "notifications" => { probe: :notifications_available?, recovery: notifications_recovery }
        }
      end

      def notifications_available?(project)
        Notification.active.where(account: project.account).limit(1).exists?
        true
      rescue StandardError
        false
      end

      def notifications_recovery
        "The tenant notifications read path is unavailable; restore database access for the " \
          "account, then the sweep retries the measurement."
      end
    end
  end
end
