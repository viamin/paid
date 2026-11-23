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
      VERSION = 7
      ROLES = %w[poll agent].freeze
      MAX_AGE = 5.minutes
      FUTURE_SKEW = 30.seconds

      Result = Data.define(:environment, :deployment_revision, :project_scope, :workers, :failure_reason) do
        def passing? = failure_reason.nil?
        def unknown? = !passing?
      end

      def self.version = VERSION
      def self.call(project:, deployment_revision:) = new(project:, deployment_revision:).call

      def initialize(project:, deployment_revision:, observations: WorkerReadinessObservation, clock: -> { Time.current }, environment: Rails.env)
        @project = project
        @deployment_revision = deployment_revision
        @observations = observations
        @clock = clock
        @environment = environment
      end

      def call
        observed_at = clock.call
        records = ROLES.to_h { |role| [ role, records_for(role, observed_at) ] }
        Result.new(
          environment: environment.to_s,
          deployment_revision:,
          project_scope: "project:#{project.id}:#{project.full_name}",
          workers: records.transform_values { |role_records| role_records.map { |record| worker_result(record) } },
          failure_reason: ROLES.lazy.map do |role|
            invalid_reason(role, records[role], deployment_revision, observed_at)
          end.find(&:present?)
        )
      end

      private

      attr_reader :clock, :deployment_revision, :environment, :observations, :project

      def records_for(role, observed_at)
        role_records = observations.for_role(role, environment:)
        live_window = role_records.where(heartbeat_at: (observed_at - MAX_AGE)..).to_a
        return live_window if live_window.any?

        role_records.reorder(heartbeat_at: :desc, id: :desc).limit(1).to_a
      end

      def invalid_reason(role, records, deployment_revision, observed_at)
        return "missing_#{role}_readiness" if records.empty?
        return "malformed_#{role}_readiness" unless records.all? { |instance| instance.heartbeat_at.present? }
        return "stale_#{role}_readiness" if records.any? { |instance| future_heartbeat?(instance, observed_at) }

        live_instances = records.select { |instance| fresh?(instance.heartbeat_at, observed_at) }
        return "stale_#{role}_readiness" if live_instances.empty?
        return "malformed_#{role}_readiness" unless live_instances.all? { |instance| usable?(instance) }
        return "#{role}_readiness_identity_mismatch" unless live_instances.all? { |instance| coherent?(instance) }
        "#{role}_revision_mismatch" unless live_instances.all? do |instance|
          adopted_revision?(instance, deployment_revision)
        end
      end

      def future_heartbeat?(record, observed_at)
        record.heartbeat_at > observed_at + FUTURE_SKEW
      end

      def usable?(record)
        record.pid.to_i.positive? && record.ready_at.present? && record.heartbeat_at.present? &&
          record.revision.present? && record.deployment_revision.present?
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
      def fresh?(heartbeat_at, observed_at)
        heartbeat_at >= observed_at - MAX_AGE
      end

      def adopted_revision?(record, deployment_revision)
        deployment_revision.present? && record.deployment_revision == deployment_revision
      end

      def worker_result(record)
        {
          "environment" => record.environment,
          "pid" => record.pid,
          "ready_at" => record.ready_at&.utc&.iso8601,
          "revision" => record.revision,
          "deployment_revision" => record.deployment_revision,
          "heartbeat_at" => record.heartbeat_at&.utc&.iso8601,
          "status" => "observed"
        }.compact
      end
    end
  end
end
