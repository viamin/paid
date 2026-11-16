# frozen_string_literal: true

module OperationalSupervisor
  class PersistIncident
    Result = Data.define(:incident, :created, :error) do
      def failure? = error.present?
    end

    def self.call(...) = new(...).call

    def initialize(account:, snapshot:, category:, severity:, affected_project_ids:, target_ids:, evidence:, model_identifier:, prompt_identifier:, policy_identifier:, now: Time.current)
      @account = account
      @snapshot = snapshot
      @attributes = { category:, severity:, affected_project_ids: canonical_project_ids(affected_project_ids), target_ids: canonical_target_ids(target_ids), evidence:, model_identifier:, prompt_identifier:, policy_identifier: }
      @now = now
    end

    # @spec OPERATIONAL-SUPERVISOR-004, OPERATIONAL-SUPERVISOR-006, OPERATIONAL-SUPERVISOR-007
    def call
      return failure("snapshot does not belong to account") unless snapshot.account_id == account.id
      return failure("targets are not snapshot members") unless target_ids_are_snapshot_members?
      return failure("operational supervisor is disabled for incident projects") unless incident_projects_enabled?

      SupervisorIncident.transaction { persist! }
    rescue ActiveRecord::RecordInvalid => error
      failure(error.record.errors.full_messages.to_sentence)
    rescue ActiveRecord::RecordNotUnique
      retry_after_deduplication_race
    end

    private

    attr_reader :account, :attributes, :now, :snapshot

    def persist!
      incident = account.supervisor_incidents.lock.find_by(fingerprint: fingerprint)
      return observe!(incident) if incident

      create!
    end

    def create!
      incident = with_status_transition_authorized do
        account.supervisor_incidents.create!(incident_attributes).tap { audit!(_1, "opened") }
      end
      Result.new(incident, true, nil)
    end

    def observe!(incident)
      previous_status = incident.status
      with_status_transition_authorized do
        incident.authorize_status_transition! unless previous_status.in?(SupervisorIncident::OPEN_STATUSES)
        incident.update!(observation_attributes(incident, previous_status))
        audit_status_change!(incident, previous_status) if incident.status != previous_status
      end
      audit!(incident, "observed")
      Result.new(incident, false, nil)
    end

    def observation_attributes(incident, previous_status)
      attributes.merge(last_seen_at: now, occurrence_count: incident.occurrence_count + 1,
        supervisor_snapshot: snapshot, status: recurring_status(previous_status))
    end

    def recurring_status(status)
      status.in?(SupervisorIncident::OPEN_STATUSES) ? status : "open"
    end

    def audit_status_change!(incident, previous_status)
      incident.supervisor_incident_audits.create!(account:, action: "status_changed", occurred_at: now,
        evidence: { "previous_status" => previous_status, "next_status" => incident.status })
    end

    def audit!(incident, action)
      incident.supervisor_incident_audits.create!(account:, action:, occurred_at: now, evidence: { "snapshot_id" => snapshot.id })
    end

    def fingerprint
      @fingerprint ||= Digest::SHA256.hexdigest({ account_id: account.id, category: attributes.fetch(:category), target_ids: attributes.fetch(:target_ids) }.to_json)
    end

    def canonical_target_ids(target_ids)
      return target_ids unless target_ids.is_a?(Hash) && target_ids.keys == [ "project_ids" ]

      { "project_ids" => canonical_project_ids(target_ids["project_ids"]) }
    end

    def canonical_project_ids(project_ids)
      return project_ids unless project_ids.is_a?(Array) && project_ids.all?(Integer)

      project_ids.uniq.sort
    end

    def incident_attributes
      attributes.merge(fingerprint:, supervisor_snapshot: snapshot, first_seen_at: now, last_seen_at: now,
        occurrence_count: 1, status: "open", retention_expires_at: now + 365.days)
    end

    def target_ids_are_snapshot_members?
      affected_project_ids_are_snapshot_members? && target_project_ids_are_snapshot_members?
    end

    def affected_project_ids_are_snapshot_members?
      snapshot_member_project_ids?(attributes.fetch(:affected_project_ids))
    end

    def target_project_ids_are_snapshot_members?
      target_ids = attributes.fetch(:target_ids)
      return false unless target_ids.is_a?(Hash) && target_ids.keys == [ "project_ids" ]

      snapshot_member_project_ids?(target_ids["project_ids"])
    end

    def snapshot_member_project_ids?(project_ids)
      project_ids.is_a?(Array) && project_ids.all? { |id| id.is_a?(Integer) && snapshot_project_ids.key?(id) }
    end

    def snapshot_project_ids
      @snapshot_project_ids ||= snapshot.included_project_ids.index_with(true)
    end

    def incident_projects_enabled?
      return false if incident_project_ids.empty?

      projects = account.projects.where(id: incident_project_ids).to_a
      projects.size == incident_project_ids.size && projects.all? { FeatureFlags.enabled?(:operational_supervisor, project: _1) }
    end

    def incident_project_ids
      @incident_project_ids ||= (
        attributes.fetch(:affected_project_ids) + attributes.fetch(:target_ids).fetch("project_ids")
      ).uniq
    end

    def retry_after_deduplication_race
      SupervisorIncident.transaction do
        incident = account.supervisor_incidents.lock.find_by!(fingerprint:)
        observe!(incident)
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

    def failure(error) = Result.new(nil, false, error)
  end
end
