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

      def call
        Result.new(desired - existing_by_fingerprint.values, existing.reject { |projection| desired_fingerprints.include?(projection.fetch("fingerprint")) })
      end

      private

      attr_reader :existing, :incidents

      def desired
        @desired ||= incidents.select { |incident| incident.status.in?(SupervisorIncident::OPEN_STATUSES) }.map do |incident|
          { "incident_id" => incident.id, "fingerprint" => incident.fingerprint, "severity" => incident.severity }
        end
      end

      def desired_fingerprints = desired.pluck("fingerprint")

      def existing_by_fingerprint = existing.index_by { |projection| projection.fetch("fingerprint") }
    end
  end
end
