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

    # @spec OPERATIONAL-SUPERVISOR-007, OPERATIONAL-SUPERVISOR-008
    def call
      incident.with_lock do
        incident.reload
        return Result.new(incident, nil) if incident.status == status
        return Result.new(incident, "operational supervisor is disabled for incident projects") unless incident_projects_enabled?

        persist_transition
        Result.new(incident, nil)
      end
    rescue ActiveRecord::RecordInvalid => error
      Result.new(incident, error.record.errors.full_messages.to_sentence)
    end

    private

    attr_reader :incident, :status, :now

    def persist_transition
      previous_status = incident.status
      with_status_transition_authorized do
        incident.authorize_status_transition!
        incident.update!(status:)
        incident.supervisor_incident_audits.create!(account: incident.account, action: "status_changed", occurred_at: now,
          evidence: { "previous_status" => previous_status, "next_status" => status })
      end
    end

    def with_status_transition_authorized
      database = SupervisorIncident.connection
      database.execute("SET LOCAL paid.supervisor_incident_status_transition = 'true'")
      yield
    ensure
      database&.execute("SET LOCAL paid.supervisor_incident_status_transition = 'false'") unless transaction_failed?(database)
    end

    def transaction_failed?(database)
      database.nil? || database.raw_connection.transaction_status == PG::PQTRANS_INERROR
    end

    def incident_projects_enabled?
      return false if incident_project_ids.empty?

      projects = Project.where(account_id: incident.account_id, id: incident_project_ids).to_a
      projects.size == incident_project_ids.size && projects.all? { FeatureFlags.enabled?(:operational_supervisor, project: _1) }
    end

    def incident_project_ids
      @incident_project_ids ||= (incident.affected_project_ids + incident.target_ids.fetch("project_ids")).uniq
    end
  end
end
