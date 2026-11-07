# frozen_string_literal: true

# Immutable audit event for project delegation posture changes.
# Each event records the actor, action, posture, policy signature, and metadata.
# @spec PROJECT-DELEGATION-001
class ProjectDelegationEvent < ApplicationRecord
  ACTIONS = %w[posture_selected].freeze

  belongs_to :account
  belongs_to :project
  belongs_to :actor, class_name: "User", optional: true, inverse_of: :project_delegation_events

  validates :action, presence: true, inclusion: { in: ACTIONS }
  validates :posture, presence: true, inclusion: { in: Project::DELEGATION_POSTURES }
  validates :account_id, presence: true
  validates :project_id, presence: true

  scope :for_project, ->(project) { where(project_id: project.id) }
  scope :by_action, ->(action) { where(action:) }
  scope :chronological, -> { order(created_at: :asc) }
  scope :recent, -> { order(created_at: :desc) }

  def self.record_posture_selection(project:, posture:, actor:, policy_signature: nil, metadata: {})
    create!(
      account: project.account,
      project:,
      actor:,
      action: "posture_selected",
      posture:,
      policy_signature:,
      metadata:
    )
  end
end
