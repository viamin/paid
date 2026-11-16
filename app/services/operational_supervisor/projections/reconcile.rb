# frozen_string_literal: true

module OperationalSupervisor
  module Projections
    class Reconcile
      Result = Data.define(:upsert, :remove)

      def self.call(...) = new(...).call

      def initialize(incidents:, existing:)
        @incidents = incidents
        @existing = existing
      end

      # @spec OPERATIONAL-SUPERVISOR-007, OPERATIONAL-SUPERVISOR-008
      def call
        Result.new(desired - existing_by_fingerprint.values, existing.reject { |projection| desired_fingerprints.include?(projection.fetch("fingerprint")) })
      end

      private

      attr_reader :existing, :incidents

      def desired
        @desired ||= incidents.select { |incident| incident.status.in?(SupervisorIncident::OPEN_STATUSES) && incident_projects_enabled?(incident) }.map do |incident|
          { "incident_id" => incident.id, "fingerprint" => incident.fingerprint, "severity" => incident.severity }
        end
      end

      def incident_projects_enabled?(incident)
        project_ids = incident.target_ids.fetch("project_ids")
        project_ids.present? && project_ids.all? { |id| enabled_projects.key?([ incident.account_id, id ]) }
      end

      def enabled_projects
        @enabled_projects ||= Project.where(id: incident_project_ids).each_with_object({}) do |project, enabled|
          enabled[[ project.account_id, project.id ]] = true if FeatureFlags.enabled?(:operational_supervisor, project:)
        end
      end

      def incident_project_ids
        @incident_project_ids ||= incidents.flat_map { |incident| incident.target_ids.fetch("project_ids") }.uniq
      end

      def desired_fingerprints = desired.pluck("fingerprint")

      def existing_by_fingerprint = existing.index_by { |projection| projection.fetch("fingerprint") }
    end
  end
end
