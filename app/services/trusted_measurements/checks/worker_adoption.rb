# frozen_string_literal: true

require "paid/worker_readiness"

module TrustedMeasurements
  module Checks
    # Collects the two fixed Temporal worker readiness facts that establish
    # whether the live worker processes, rather than only the mounted checkout,
    # adopted the deployment revision. It never opens a caller-selected host
    # path or inspects process arguments, environment, or credentials.
    # @spec TRUSTED-MEASUREMENTS-008
    class WorkerAdoption
      VERSION = 1
      ROLES = %w[poll agent].freeze
      MAX_AGE = 5.minutes
      FUTURE_SKEW = 30.seconds

      Result = Data.define(:environment, :deployment_revision, :project_scope, :workers, :failure_reason) do
        def passing? = failure_reason.nil?
        def unknown? = !passing?
      end

      def self.version = VERSION
      def self.call(project:) = new(project:).call

      def initialize(project:, readiness: Paid::WorkerReadiness, clock: -> { Time.current }, process_alive: nil)
        @project = project
        @readiness = readiness
        @clock = clock
        @process_alive = process_alive || ->(pid) { Process.kill(0, pid); true }
      end

      def call
        snapshots = ROLES.to_h { |role| [ role, readiness.temporal_snapshot(role) ] }
        reason = snapshots.values.lazy.map { |snapshot| invalid_reason(snapshot) }.find(&:present?)
        Result.new(
          environment: Rails.env.to_s,
          deployment_revision: DeploymentSignal.current,
          project_scope: "project:#{project.id}:#{project.full_name}",
          workers: snapshots.transform_values { |snapshot| worker_result(snapshot) },
          failure_reason: reason
        )
      end

      private

      attr_reader :clock, :process_alive, :project, :readiness

      def invalid_reason(snapshot)
        return "missing_#{snapshot.role}_readiness" if snapshot.error == "missing"
        return "malformed_#{snapshot.role}_readiness" if snapshot.error
        return "#{snapshot.role}_pid_not_alive" unless alive?(snapshot.pid)
        return "#{snapshot.role}_readiness_identity_mismatch" unless coherent_timestamp?(snapshot)
        return "stale_#{snapshot.role}_readiness" unless fresh?(snapshot.ready_at)
        "#{snapshot.role}_revision_mismatch" unless snapshot.revision == DeploymentSignal.current
      end

      def alive?(pid)
        process_alive.call(pid)
      rescue Errno::ESRCH, Errno::EPERM
        false
      end

      def coherent_timestamp?(snapshot)
        snapshot.modified_at >= snapshot.ready_at - 1.second
      end

      def fresh?(ready_at)
        ready_at <= clock.call + FUTURE_SKEW && ready_at >= clock.call - MAX_AGE
      end

      def worker_result(snapshot)
        {
          "pid" => snapshot.pid,
          "ready_at" => snapshot.ready_at&.utc&.iso8601,
          "revision" => snapshot.revision,
          "modified_at" => snapshot.modified_at&.utc&.iso8601,
          "status" => snapshot.error || "observed"
        }.compact
      end
    end
  end
end
