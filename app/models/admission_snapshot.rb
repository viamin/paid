# frozen_string_literal: true

# Records a snapshot of the admission state at each delegated-work boundary.
# This allows tracking which revisions and policy were active at each step,
# enabling bounded recovery and preventing in-flight broadening.
#
# @spec PROJECT-DELEGATION-004 @spec PROJECT-DELEGATION-006
class AdmissionSnapshot < ApplicationRecord
  BOUNDARIES = %w[create queue dequeue retry follow_up repair closeout].freeze
  STATUSES = %w[active rolled_back expired revoked].freeze

  belongs_to :account
  belongs_to :project
  belongs_to :issue
  belongs_to :bounded_delegated_action

  validates :boundary, presence: true, inclusion: { in: BOUNDARIES }
  validates :action, presence: true, inclusion: { in: BoundedDelegatedAction::ACTIONS }
  validates :status, presence: true, inclusion: { in: STATUSES }
  validate :snapshot_is_object

  scope :active, -> { where(status: "active").where("expires_at > ? OR expires_at IS NULL", Time.current) }
  scope :for_action, ->(action) { where(action: action) }
  scope :for_boundary, ->(boundary) { where(boundary: boundary) }

  def self.record(bounded_action:, boundary:, snapshot:)
    create!(
      account: bounded_action.account,
      project: bounded_action.project,
      issue: bounded_action.issue,
      bounded_delegated_action: bounded_action,
      action: bounded_action.action,
      boundary: boundary.to_s,
      snapshot: snapshot,
      status: "active",
      expires_at: bounded_action.expires_at
    )
  end

  def active?
    status == "active" && (expires_at.nil? || expires_at > Time.current)
  end

  def rollback!(reason:, user: nil)
    with_lock do
      return false unless status == "active"

      update!(status: "rolled_back", rollback_reason: reason)
      Audit::RecordEvent.call(
        action: "admission_snapshot.rolled_back",
        actor: user,
        subject: self,
        metadata: { "boundary" => boundary, "action" => action, "reason" => reason }
      )
    end
    true
  end

  def revoke!
    return false unless status == "active"

    with_lock do
      update!(status: "revoked", rollback_reason: "authorization_revoked")
      Audit::RecordEvent.call(
        action: "admission_snapshot.revoked",
        subject: self,
        metadata: { "boundary" => boundary, "action" => action }
      )
    end
    true
  end

  def expire!
    return false unless status == "active"

    with_lock do
      update!(status: "expired", rollback_reason: "authorization_expired")
      Audit::RecordEvent.call(
        action: "admission_snapshot.expired",
        subject: self,
        metadata: { "boundary" => boundary, "action" => action }
      )
    end
    true
  end

  private

  def snapshot_is_object
    errors.add(:snapshot, "must be an object") unless snapshot.is_a?(Hash)
  end
end
