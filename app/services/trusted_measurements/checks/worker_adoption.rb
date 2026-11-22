# frozen_string_literal: true

module TrustedMeasurements
  module Checks
    # Collects the durable readiness observations the two Temporal worker roles
    # publish about themselves while running, to establish whether the live
    # worker processes, rather than only the mounted checkout, adopted the
    # deployment revision. Each owning role heartbeats its identity (PID, boot
    # time, booted revision, latest beat) into the shared application database,
    # so this check observes the workers from any role's container — including
    # the job container — without reading host files, probing a foreign PID
    # namespace, or inspecting process arguments, environment, or credentials.
    # @spec TRUSTED-MEASUREMENTS-008
    class WorkerAdoption
      VERSION = 2
      ROLES = %w[poll agent].freeze
      MAX_AGE = 5.minutes
      FUTURE_SKEW = 30.seconds

      Result = Data.define(:environment, :deployment_revision, :project_scope, :workers, :failure_reason) do
        def passing? = failure_reason.nil?
        def unknown? = !passing?
      end

      def self.version = VERSION
      def self.call(project:) = new(project:).call

      def initialize(project:, observations: WorkerReadinessObservation, clock: -> { Time.current })
        @project = project
        @observations = observations
        @clock = clock
      end

      def call
        records = ROLES.to_h { |role| [ role, observations.for_role(role) ] }
        Result.new(
          environment: Rails.env.to_s,
          deployment_revision: DeploymentSignal.current,
          project_scope: "project:#{project.id}:#{project.full_name}",
          workers: records.transform_values { |record| worker_result(record) },
          failure_reason: ROLES.lazy.map { |role| invalid_reason(role, records[role]) }.find(&:present?)
        )
      end

      private

      attr_reader :clock, :observations, :project

      def invalid_reason(role, record)
        return "missing_#{role}_readiness" unless record
        return "malformed_#{role}_readiness" unless usable?(record)
        return "#{role}_readiness_identity_mismatch" unless coherent?(record)
        return "stale_#{role}_readiness" unless fresh?(record.heartbeat_at)
        "#{role}_revision_mismatch" unless adopted_revision?(record)
      end

      def usable?(record)
        record.pid.to_i.positive? && record.ready_at.present? && record.heartbeat_at.present?
      end

      # A beat older than the boot it reports cannot be this process's own
      # liveness observation.
      def coherent?(record)
        record.heartbeat_at >= record.ready_at - FUTURE_SKEW
      end

      # Freshness is the live process's heartbeat, not its static boot
      # receipt: a healthy worker keeps beating for its whole lifetime, and a
      # dead or stuck worker stops, so long-lived workers stay current while
      # interrupted adoption fails closed.
      def fresh?(heartbeat_at)
        heartbeat_at <= clock.call + FUTURE_SKEW && heartbeat_at >= clock.call - MAX_AGE
      end

      def adopted_revision?(record)
        revision = DeploymentSignal.current
        revision.present? && record.revision == revision
      end

      def worker_result(record)
        return { "status" => "missing" } unless record

        {
          "pid" => record.pid,
          "ready_at" => record.ready_at&.utc&.iso8601,
          "revision" => record.revision,
          "heartbeat_at" => record.heartbeat_at&.utc&.iso8601,
          "status" => "observed"
        }.compact
      end
    end
  end
end
