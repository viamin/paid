# frozen_string_literal: true

class IssueMergeSubscription < ApplicationRecord
  ON_MERGE = "on_merge"

  belongs_to :issue
  belongs_to :user

  validates :subscription_type, presence: true, inclusion: { in: [ ON_MERGE ] }
  validates :issue_id, uniqueness: { scope: [ :user_id, :subscription_type ] }
  validate :user_and_issue_belong_to_same_account

  before_validation :default_subscription_type

  scope :on_merge, -> { where(subscription_type: ON_MERGE) }

  private

  def default_subscription_type
    self.subscription_type ||= ON_MERGE
  end

  def user_and_issue_belong_to_same_account
    return unless user && issue
    return if user.account_id == issue.project.account_id

    errors.add(:user, "must belong to the same account as the issue")
  end
end
