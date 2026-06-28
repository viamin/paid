# frozen_string_literal: true

class RunnerCredential < ApplicationRecord
  has_logidze

  belongs_to :account
  belongs_to :runner
  belongs_to :created_by, class_name: "User", optional: true

  encrypts :token

  validates :runner_id, uniqueness: { scope: %i[account_id], conditions: -> { where(revoked_at: nil) }, message: "already has a credential" }
  validates :token, presence: true
  validate :runner_belongs_to_same_account
  validate :created_by_belongs_to_same_account, if: -> { created_by.present? }

  before_validation :assign_account_from_runner

  scope :active, -> { where(revoked_at: nil) }
  scope :revoked, -> { where.not(revoked_at: nil) }

  def active?
    revoked_at.nil?
  end

  def revoked?
    revoked_at.present?
  end

  def revoke!
    update_column(:revoked_at, Time.current)
  end

  private

  def assign_account_from_runner
    self.account_id = runner.user&.account_id if runner.present? && account_id.blank?
  end

  def runner_belongs_to_same_account
    return if runner.blank? || runner.user&.account_id == account_id

    errors.add(:runner, "must belong to the same account")
  end

  def created_by_belongs_to_same_account
    return if created_by.account_id == account_id

    errors.add(:created_by, "must belong to the same account")
  end
end
