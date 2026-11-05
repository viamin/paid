# frozen_string_literal: true

module Automation
  # Immutable admission receipt for delegated work. A later posture broadening
  # is intentionally irrelevant to an already admitted run.
  # @spec BOUNDED-PHASE-AUTHORIZATION-004 @spec BOUNDED-PHASE-AUTHORIZATION-009
  class AdmissionSnapshot
    STATES = %w[active held expired revoked stopped completed].freeze
    Decision = Data.define(:allowed, :reason) do
      def allowed? = allowed
    end

    def self.capture(agent_run:, posture:, intent_revision:, acceptance_revision:, evidence_revision:,
      policy_signature:, phase:, stop_before: nil, expires_at: nil, now: Time.current)
      snapshot = {
        "version" => 1,
        "posture" => posture.to_s,
        "posture_revision" => agent_run.project.delegation_posture_revision,
        "intent_revision" => intent_revision,
        "acceptance_revision" => acceptance_revision,
        "evidence_revision" => evidence_revision,
        "policy_signature" => policy_signature.to_s,
        "phase" => phase.to_s,
        "stop_before" => stop_before&.to_s,
        "admitted_at" => now.iso8601
      }.compact

      agent_run.with_lock do
        return agent_run.admission_snapshot if agent_run.admission_snapshot.present?

        agent_run.update_columns(
          admission_snapshot: snapshot,
          admission_state: "active",
          admission_expires_at: expires_at,
          updated_at: Time.current
        )
      end
      Audit::RecordEvent.call(action: "delegation.admission_snapshotted", subject: agent_run,
        metadata: snapshot.merge("expires_at" => expires_at&.iso8601).compact)
      snapshot
    end

    def self.check(agent_run:, posture:, intent_revision:, acceptance_revision:, evidence_revision:,
      policy_signature:, phase: nil, now: Time.current)
      snapshot = agent_run.admission_snapshot.to_h.deep_stringify_keys
      return Decision.new(false, :missing_snapshot) if snapshot.empty?
      return Decision.new(false, agent_run.admission_state.to_sym) unless agent_run.admission_state == "active"
      return Decision.new(false, :expired) if agent_run.admission_expires_at && agent_run.admission_expires_at <= now

      expected = {
        "posture" => posture.to_s,
        "intent_revision" => intent_revision,
        "acceptance_revision" => acceptance_revision,
        "evidence_revision" => evidence_revision,
        "policy_signature" => policy_signature.to_s
      }
      mismatched = expected.keys.find { |key| snapshot[key].to_s != expected[key].to_s }
      return Decision.new(false, :revision_changed) if mismatched

      Decision.new(true, :admitted)
    end
  end
end
