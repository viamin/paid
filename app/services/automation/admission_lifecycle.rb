# frozen_string_literal: true

module Automation
  # Conservative, auditable lifecycle transitions for admitted work.
  # Running work is never force-killed; only its next boundary is blocked.
  # @spec BOUNDED-PHASE-AUTHORIZATION-009
  class AdmissionLifecycle
    TRANSITIONS = {
      hold: [ "held", "delegation.admission_held" ],
      expire: [ "expired", "delegation.admission_expired" ],
      revoke: [ "revoked", "delegation.admission_revoked" ],
      stop: [ "stopped", "delegation.bounded_stop" ],
      complete: [ "completed", "delegation.admission_completed" ]
    }.freeze

    def self.call(agent_run:, transition:, reason:, actor: nil)
      new(agent_run:, transition:, reason:, actor:).call
    end

    def initialize(agent_run:, transition:, reason:, actor: nil)
      @agent_run = agent_run
      @transition = transition.to_sym
      @reason = reason.to_s
      @actor = actor
    end

    def call
      state, action = TRANSITIONS.fetch(transition)
      changed = agent_run.with_lock do
        next false unless agent_run.admission_state == "active"

        agent_run.update!(admission_state: state, admission_hold_reason: reason, admission_changed_at: Time.current)
      end
      return false unless changed

      Audit::RecordEvent.call(action:, actor:, subject: agent_run,
        metadata: { "reason" => reason, "admission_snapshot" => agent_run.admission_snapshot })
      true
    end

    private

    attr_reader :agent_run, :transition, :reason, :actor
  end
end
