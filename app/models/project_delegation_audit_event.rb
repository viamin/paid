# frozen_string_literal: true

class ProjectDelegationAuditEvent < ApplicationRecord
  belongs_to :project
  belongs_to :account
  belongs_to :actor, class_name: "User", optional: true

  # @spec PROJECT-DELEGATION-001 @spec PROJECT-DELEGATION-006 @spec PROJECT-DELEGATION-007 @spec PROJECT-DELEGATION-008
  POSTURE_CHANGED = "posture_changed"
  CHECKPOINT_SETTLED = "checkpoint_settled"
  ACTION_ADMITTED = "action_admitted"
  ACTION_COMPLETED = "action_completed"
  DECISION_ROUTED = "decision_routed"

  EVENT_TYPES = [
    POSTURE_CHANGED,
    CHECKPOINT_SETTLED,
    ACTION_ADMITTED,
    ACTION_COMPLETED,
    DECISION_ROUTED
  ].freeze

  validates :project_id, presence: true
  validates :account_id, presence: true
  validates :event_type, presence: true, inclusion: { in: EVENT_TYPES }
  validates :event_data, presence: true
  validates :evidence_snapshot, presence: true

  def self.record(project:, account:, event_type:, actor: nil, event_data: {}, evidence_snapshot: {}, revision_signature: nil)
    create!(
      project: project,
      account: account,
      event_type: event_type,
      actor: actor,
      actor_name: actor&.name,
      event_data: event_data,
      evidence_snapshot: evidence_snapshot,
      revision_signature: revision_signature
    )
  end
end
