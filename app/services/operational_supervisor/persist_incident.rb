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
      @attributes = { category:, severity:, affected_project_ids:, target_ids:, evidence:, model_identifier:, prompt_identifier:, policy_identifier: }
      @now = now
    end

    def call
      return failure("snapshot does not belong to account") unless snapshot.account_id == account.id
      return failure("targets are not snapshot members") unless target_ids_are_snapshot_members?

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
      incident = account.supervisor_incidents.create!(incident_attributes)
      audit!(incident, "opened")
      Result.new(incident, true, nil)
    end

    def observe!(incident)
      incident.update!(last_seen_at: now, occurrence_count: incident.occurrence_count + 1, supervisor_snapshot: snapshot)
      audit!(incident, "observed")
      Result.new(incident, false, nil)
    end

    def audit!(incident, action)
      incident.supervisor_incident_audits.create!(account:, action:, occurred_at: now, evidence: { "snapshot_id" => snapshot.id })
    end

    def fingerprint
      @fingerprint ||= Digest::SHA256.hexdigest({ account_id: account.id, category: attributes.fetch(:category), target_ids: attributes.fetch(:target_ids) }.to_json)
    end

    def incident_attributes
      attributes.merge(fingerprint:, supervisor_snapshot: snapshot, first_seen_at: now, last_seen_at: now,
        occurrence_count: 1, status: "open", retention_expires_at: now + 365.days)
    end

    def target_ids_are_snapshot_members?
      target_projects = Array(attributes.fetch(:affected_project_ids)).map(&:to_i)
      target_projects.all? { |id| snapshot.included_project_ids.include?(id) }
    end

    def retry_after_deduplication_race
      incident = account.supervisor_incidents.find_by!(fingerprint:)
      observe!(incident)
    end

    def failure(error) = Result.new(nil, false, error)
  end
end
