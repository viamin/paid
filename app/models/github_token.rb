# frozen_string_literal: true

class GithubToken < ApplicationRecord
  # GitHub token format patterns
  # Classic PAT: ghp_xxxx (40 chars after prefix)
  # Fine-grained PAT: github_pat_xxxx
  # OAuth: gho_xxxx
  # User-to-server: ghu_xxxx
  # Server-to-server: ghs_xxxx
  # Refresh token: ghr_xxxx
  GITHUB_TOKEN_PATTERN = /\A(ghp_[A-Za-z0-9]{36,}|github_pat_[A-Za-z0-9_]{22,}|gh[ours]_[A-Za-z0-9]{36,})\z/

  belongs_to :account
  belongs_to :created_by, class_name: "User", optional: true

  has_many :projects, dependent: :restrict_with_error

  encrypts :token

  validates :name, presence: true, uniqueness: { scope: :account_id }
  validates :token, presence: true
  validate :token_format_valid, if: -> { token.present? }
  validate :created_by_belongs_to_same_account, if: -> { created_by.present? }

  scope :active, -> { where(revoked_at: nil).where("expires_at IS NULL OR expires_at > ?", Time.current) }
  scope :expired, -> { where.not(expires_at: nil).where("expires_at <= ?", Time.current) }
  scope :revoked, -> { where.not(revoked_at: nil) }

  def active?
    revoked_at.nil? && (expires_at.nil? || expires_at > Time.current)
  end

  def expired?
    expires_at.present? && expires_at <= Time.current
  end

  def revoked?
    revoked_at.present?
  end

  def revoke!
    update!(revoked_at: Time.current)
  end

  def touch_last_used!
    update_column(:last_used_at, Time.current)
  end

  private

  def token_format_valid
    return if token.match?(GITHUB_TOKEN_PATTERN)

    errors.add(:token, "must be a valid GitHub token format")
  end

  def created_by_belongs_to_same_account
    return if created_by.account_id == account_id

    errors.add(:created_by, "must belong to the same account")
  end
end
