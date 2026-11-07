# frozen_string_literal: true

# Project delegation orchestration: default-conservative posture, authorized
# selection, effective-posture projection, and immutable audit events.
#
# @spec PROJECT-DELEGATION-001 @spec PROJECT-DELEGATION-005
module ProjectDelegation
  def self.projection_for(project:)
    Projection.call(project:)
  end

  def self.intent_checkpoint_for(issue:)
    IntentCheckpoint::Plan.for_issue(issue)
  end

  def self.evaluate_action(project:, work_item:, action_class:, evidence_snapshot: {})
    ActionPlan.call(
      project: project,
      work_item: work_item,
      action_class: action_class,
      evidence_snapshot: evidence_snapshot
    )
  end

  # Authorize a new delegation posture and record immutable audit event
  # @spec PROJECT-DELEGATION-001 @spec PROJECT-DELEGATION-006
  def self.authorize_posture(project:, posture:, actor:, enabled_action_classes: [])
    raise ArgumentError, "Invalid posture: #{posture}" unless Projection::VALID_POSTURES.include?(posture)

    project.transaction do
      # Update project with new posture
      posture_signature = Automation::EffectivePolicy.call(
        project: project,
        phase: Automation::Phases::CODING,
        continuation_selected: true
      ).signature if posture == Projection::BOUNDED_DELIVERY_POSTURE

      project.update!(
        delegation_posture: posture,
        delegation_authorized_by: actor,
        delegation_authorized_at: Time.current,
        delegation_posture_signature: posture_signature,
        delegation_enabled_action_classes: enabled_action_classes
      )

      # Record immutable audit event
      ProjectDelegationAuditEvent.record(
        project: project,
        account: project.account,
        event_type: ProjectDelegationAuditEvent::POSTURE_CHANGED,
        actor: actor,
        event_data: {
          new_posture: posture,
          enabled_action_classes: enabled_action_classes,
          authorized_by: actor.name
        },
        evidence_snapshot: {
          timestamp: Time.current
        },
        revision_signature: posture_signature
      )

      project
    end
  rescue StandardError => e
    Rails.logger.error(
      message: "project_delegation.authorize_posture_failed",
      project_id: project.id,
      posture: posture,
      actor_id: actor.id,
      error: e.message
    )
    raise
  end
end
