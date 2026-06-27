# frozen_string_literal: true

class RunnerCredential < ApplicationRecord
  has_logidze
  AUTH_KINDS = %w[oauth_token api_key signing_token].freeze

  belongs_to :account
  belongs_to :created_by, class_name: "User", optional: true

  encrypts :token

  validates :name, presence: true, uniqueness: { scope: %i[account_id runner_key] }
  validates :runner_key, presence: true
  validates :auth_kind, presence: true, inclusion: { in: AUTH_KINDS }
  validates :token, presence: true
  validate :created_by_belongs_to_same_account, if: -> { created_by.present? }

  scope :active, -> { where(revoked_at: nil).where("expires_at IS NULL OR expires_at > ?", Time.current) }
  scope :revoked, -> { where.not(revoked_at: nil) }
  scope :for_runner, ->(runner_key) { where(runner_key: runner_key.to_s) }
  scope :long_lived, -> { where(long_lived: true) }

  def active?
    revoked_at.nil? && (expires_at.nil? || expires_at > Time.current)
  end

  def revoked?
    revoked_at.present?
  end

  def expired?
    !revoked? && !long_lived? && expires_at.present? && expires_at <= Time.current
  end

  def revoke!
    update_column(:revoked_at, Time.current)
  end

  private

  def created_by_belongs_to_same_account
    return if created_by.account_id == account_id

    errors.add(:created_by, "must belong to the same account")
  end
end
