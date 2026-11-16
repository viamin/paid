# frozen_string_literal: true

module OperationalSupervisor
  class TransitionIncidentStatus
    Result = Data.define(:incident, :error) do
      def failure? = error.present?
    end

    def self.call(...) = new(...).call

    def initialize(incident:, status:, now: Time.current)
      @incident = incident
      @status = status.to_s
      @now = now
    end

    # @spec OPERATIONAL-SUPERVISOR-007
    def call
      return Result.new(incident, nil) if incident.status == status

      persist_transition
      Result.new(incident, nil)
    rescue ActiveRecord::RecordInvalid => error
      Result.new(incident, error.record.errors.full_messages.to_sentence)
    end

    private

    attr_reader :incident, :status, :now

    def persist_transition
      incident.transaction do
        previous_status = incident.status
        enable_status_transition!
        incident.authorize_status_transition!
        incident.update!(status:)
        incident.supervisor_incident_audits.create!(account: incident.account, action: "status_changed", occurred_at: now,
          evidence: { "previous_status" => previous_status, "next_status" => status })
      end
    end

    def enable_status_transition!
      SupervisorIncident.connection.execute("SET LOCAL paid.supervisor_incident_status_transition = 'true'")
    end
  end
end
