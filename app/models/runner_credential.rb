# frozen_string_literal: true

class RunnerCredential < ApplicationRecord
  has_logidze

  belongs_to :account
  belongs_to :created_by, class_name: "User", optional: true

  encrypts :token

  validates :runner_key, presence: true,
    inclusion: { in: ->(_) { Runner.supported_runner_keys }, message: "is not supported" },
    uniqueness: {
      scope: %i[account_id],
      conditions: -> { where(revoked_at: nil) },
      message: "already has a credential"
    }
  validates :token, presence: true
  validate :created_by_belongs_to_same_account, if: -> { created_by.present? }

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

  def display_name
    Runner.display_name_for(runner_key)
  end

  private

  def created_by_belongs_to_same_account
    return if created_by.account_id == account_id

    errors.add(:created_by, "must belong to the same account")
  end
end
