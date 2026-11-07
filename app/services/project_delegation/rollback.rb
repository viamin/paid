# frozen_string_literal: true

module ProjectDelegation
  # Conservative rollback (RDR-080): an explicit narrowing that selects
  # `conservative`, blocks the next delegated boundary for in-flight work,
  # preserves every authorization, evidence, and audit row, and routes one
  # focused recovery decision per in-flight delegated authorization. It never
  # reinterprets or deletes history, and no project is enrolled by the
  # rollback itself: a project without a posture record gains a conservative
  # row, never a delegating one.
  #
  # @spec PROJECT-DELEGATION-006
  class Rollback
    NOTIFICATION_SOURCE = "project_delegation_rollback"

    Result = Data.define(:posture, :affected_authorizations)

    def self.call(project:, actor:, reason: nil)
      affected = in_flight_delegated_work(project)
      posture = narrow_to_conservative(project:, actor:, reason:)

      affected.each { |authorization| route_recovery_decision(authorization, reason: reason) }
      Audit::RecordEvent.call(
        action: "project_delegation.rollback_completed",
        actor: actor,
        subject: posture,
        metadata: { "reason" => reason, "affected_authorizations" => affected.size }
      )
      Result.new(posture: posture, affected_authorizations: affected)
    end

    # In-flight delegated work: still-active authorizations that were admitted
    # under a delegating posture. Authorizations admitted while conservative
    # were never running under delegated authority and create no recovery
    # noise.
    def self.in_flight_delegated_work(project)
      project.bounded_delegated_actions.active.includes(:issue)
        .select { |authorization| authorization.evidence.to_h["posture_level"] == ProjectDelegationPosture::DELEGATING_LEVEL }
    end

    # One recovery decision per affected authorization, deduplicated by the
    # focused-decision identity so repeated rollbacks never re-prompt.
    def self.route_recovery_decision(authorization, reason:)
      Automation::FocusedDecision.call(
        account: authorization.account,
        subject: authorization.issue,
        source: NOTIFICATION_SOURCE,
        title: "Delegated work paused by delegation rollback",
        description: "The project delegation posture rolled back to conservative; " \
                     "review this authorization before any further delegated action.",
        metadata: {
          "authorization_id" => authorization.id,
          "boundary" => "rollback",
          "reasons" => [ "posture_rollback" ],
          "reason" => reason
        }
      )
    end

    def self.narrow_to_conservative(project:, actor:, reason:)
      record = project.project_delegation_posture
      return record.rollback!(user: actor, reason: reason).reload if record

      created = project.create_project_delegation_posture!(
        account: project.account,
        level: ProjectDelegationPosture::CONSERVATIVE,
        policy_signature: ProjectDelegationPosture.policy_signature_for(project),
        enabled_action_classes: ProjectDelegationPosture.action_classes_for(ProjectDelegationPosture::CONSERVATIVE),
        selected_by: actor,
        selected_at: Time.current
      )
      Audit::RecordEvent.call(
        action: "project_delegation.rolled_back",
        actor: actor,
        subject: created,
        metadata: { "reason" => reason, "from_level" => "default", "revision" => created.revision }
      )
      created
    end
    private_class_method :narrow_to_conservative
  end
end
