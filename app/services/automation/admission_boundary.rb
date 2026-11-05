# frozen_string_literal: true

module Automation
  # Shared dequeue/retry boundary for runs that carry a delegation receipt.
  # Revision-specific evidence checks remain owned by their admission service;
  # this boundary enforces the universally available posture and lifecycle data.
  # @spec BOUNDED-PHASE-AUTHORIZATION-004 @spec BOUNDED-PHASE-AUTHORIZATION-009
  class AdmissionBoundary
    def self.call(agent_run:, now: Time.current)
      new(agent_run:, now:).call
    end

    def initialize(agent_run:, now: Time.current)
      @agent_run = agent_run
      @now = now
    end

    def call
      return false if agent_run.admission_snapshot.blank?
      return hold(:admission_expired) if expired?
      return hold(:admission_state) unless agent_run.admission_state == "active"
      return hold(:posture_revision_changed) unless posture_current?

      false
    end

    private

    attr_reader :agent_run, :now

    def expired?
      agent_run.admission_expires_at.present? && agent_run.admission_expires_at <= now
    end

    def posture_current?
      snapshot = agent_run.admission_snapshot.deep_stringify_keys
      snapshot["posture"] == agent_run.project.delegation_posture &&
        snapshot["posture_revision"].to_i == agent_run.project.delegation_posture_revision
    end

    def hold(reason)
      transition = reason == :admission_expired ? :expire : :hold
      AdmissionLifecycle.call(agent_run:, transition:, reason: reason.to_s)
      true
    end
  end
end
