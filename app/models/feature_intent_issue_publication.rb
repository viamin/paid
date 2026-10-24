# frozen_string_literal: true

# Durable idempotency boundary for publishing a planning-held GitHub issue.
# The receipt is committed before the remote create and records the returned
# GitHub identity before local issue synchronization can run.
class FeatureIntentIssuePublication < ApplicationRecord
  belongs_to :feature_intent

  validates :task_digest, presence: true, length: { maximum: 16 }, uniqueness: { scope: :feature_intent_id }
  validates :remote_issue_id, numericality: { only_integer: true }, allow_nil: true
  validates :remote_issue_number, numericality: { only_integer: true, greater_than: 0 }, allow_nil: true
  validate :remote_issue_identity_is_complete

  private

  def remote_issue_identity_is_complete
    return if remote_issue_id.present? == remote_issue_number.present?

    errors.add(:remote_issue_id, "and remote_issue_number must be recorded together")
  end
end
