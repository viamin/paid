# frozen_string_literal: true

# An explicit hold on delegated work for one project (RDR-080). A hold pauses
# the next delegated action without changing the posture, the admission
# snapshots, or the delegated evidence. It is released by an authorized actor
# rather than by a posture change, and both transitions are recorded as
# immutable audit events.
#
# @spec PROJECT-DELEGATION-010
class ProjectDelegationHold < ApplicationRecord
  STATUSES = %w[held released].freeze

  belongs_to :account
  belongs_to :project
  belongs_to :held_by, class_name: "User", optional: true, inverse_of: :held_delegation_holds
  belongs_to :released_by, class_name: "User", optional: true, inverse_of: :released_delegation_holds

  validates :status, presence: true, inclusion: { in: STATUSES }
  validates :reason, presence: true
  validates :held_at, presence: true
  validate :account_matches_project
  validate :actor_belongs_to_account

  scope :held, -> { where(status: "held") }

  def held?
    status == "held"
  end

  def released?
    status == "released"
  end

  # Lifecycle write only: callers reach this through
  # ProjectDelegation::ReleaseHold, which enforces the project policy before
  # the hold is lifted. The model still fails closed on cross-account actors.
  def release!(user:)
    with_lock do
      return false unless held?

      update!(status: "released", released_at: Time.current, released_by: user)
      Audit::RecordEvent.call(
        action: "project_delegation.hold_released",
        actor: user,
        subject: self,
        metadata: { "project_id" => project_id, "reason" => reason }
      )
    end
    true
  end

  private

  def account_matches_project
    errors.add(:account, "must match the project") if account && project && account_id != project.account_id
  end

  def actor_belongs_to_account
    errors.add(:held_by, "must belong to the account") if held_by && account && held_by.account_id != account_id
    errors.add(:released_by, "must belong to the account") if released_by && account && released_by.account_id != account_id
  end
end
