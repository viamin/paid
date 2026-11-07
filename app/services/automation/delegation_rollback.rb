# frozen_string_literal: true

module Automation
  # Handles conservative rollback of delegated authorization when the project
  # posture changes, policy narrows, authorization expires, or is revoked.
  # Preserves audit evidence and routes affected work to focused Inbox decisions.
  # @spec PROJECT-DELEGATION-006
  class DelegationRollback
    ROLLBACK_REASONS = {
      posture_narrowed: "project_delegation_posture_narrowed",
      policy_narrowed: "effective_policy_narrowed",
      authorization_expired: "bounded_action_expired",
      authorization_revoked: "bounded_action_revoked",
      stop_phase_activated: "bounded_stop_phase_activated"
    }.freeze

    def self.on_posture_change(project:, old_posture:, new_posture:)
      return if new_posture == old_posture
      return if posture_broader?(old_posture, new_posture)

      new(project: project, reason: :posture_narrowed).call
    end

    def self.on_expiry(bounded_action:)
      new(bounded_action: bounded_action, reason: :authorization_expired).call
    end

    def initialize(project: nil, bounded_action: nil, reason:)
      @project = project
      @bounded_action = bounded_action
      @reason = reason
    end

    def call
      if bounded_action
        rollback_single_authorization
      else
        rollback_project_authorizations
      end
    end

    private

    attr_reader :project, :bounded_action, :reason

    # Rolls back all active admission snapshots for a single authorization
    # when it expires or is revoked.
    def rollback_single_authorization
      snapshots = AdmissionSnapshot
        .where(bounded_delegated_action: bounded_action)
        .where(status: "active")

      snapshots.find_each do |snapshot|
        snapshot.rollback!(reason: ROLLBACK_REASONS[reason])
        route_recovery_decision(snapshot)
      end
    end

    # Rolls back active admission snapshots across a project when its
    # delegation posture narrows or effective policy changes.
    def rollback_project_authorizations
      snapshots = AdmissionSnapshot
        .where(project: project)
        .where(status: "active")

      snapshots.find_each do |snapshot|
        snapshot.rollback!(reason: ROLLBACK_REASONS[reason])
        route_recovery_decision(snapshot)
      end
    end

    # Routes a recovery decision to the Inbox when an admission snapshot is rolled back.
    def route_recovery_decision(snapshot)
      FocusedDecision.call(
        account: snapshot.account,
        subject: snapshot.issue,
        source: "delegation_rollback",
        title: "Delegated work needs re-admission",
        description: describe_rollback(snapshot),
        metadata: {
          "snapshot_id" => snapshot.id,
          "action" => snapshot.action,
          "boundary" => snapshot.boundary,
          "reason" => ROLLBACK_REASONS[reason]
        }
      )
    rescue => e
      Rails.logger.error(
        message: "automation.delegation_rollback_decision_failed",
        error_class: e.class.name,
        error: e.message,
        snapshot_id: snapshot.id
      )
    end

    def describe_rollback(snapshot)
      reason_text = describe_reason(snapshot)
      "Delegated #{snapshot.action} work on #{snapshot.issue.title} cannot proceed: #{reason_text}. " \
        "Review and re-admit before continuing."
    end

    def describe_reason(snapshot)
      case reason
      when :posture_narrowed
        "project delegation posture narrowed"
      when :policy_narrowed
        "effective phase policy changed"
      when :authorization_expired
        "authorization expired at #{snapshot.expires_at.to_s(:short)}"
      when :authorization_revoked
        "authorization was revoked"
      when :stop_phase_activated
        "phase reached bounded stop"
      else
        "authorization no longer valid"
      end
    end

    def self.posture_broader?(old, new)
      # Conservative -> Bounded: broader
      # Bounded -> Conservative: narrower
      old == "conservative" && new == "bounded_delivery"
    end
  end
end
