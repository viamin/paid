# frozen_string_literal: true

class LinearToken < ApplicationRecord
  LINEAR_TOKEN_PATTERN = /\Alin_api_[A-Za-z0-9]{32,}\z/
  VALIDATION_STATUSES = %w[pending validating validated failed].freeze

  belongs_to :account
  belongs_to :created_by, class_name: "User", optional: true

  encrypts :token

  validates :name, presence: true, uniqueness: { scope: :account_id }
  validates :token, presence: true
  validates :validation_status, inclusion: { in: VALIDATION_STATUSES }
  validate :token_format_valid, if: -> { token.present? }
  validate :created_by_belongs_to_same_account, if: -> { created_by.present? }

  scope :active, -> { where(revoked_at: nil).where("expires_at IS NULL OR expires_at > ?", Time.current) }
  scope :revoked, -> { where.not(revoked_at: nil) }

  def active?
    revoked_at.nil? && (expires_at.nil? || expires_at > Time.current)
  end

  def revoked?
    revoked_at.present?
  end

  def revoke!
    update!(revoked_at: Time.current)
  end

  def validation_pending?
    validation_status == "pending"
  end

  def validated?
    validation_status == "validated"
  end

  def validation_failed?
    validation_status == "failed"
  end

  private

  def token_format_valid
    return if token.match?(LINEAR_TOKEN_PATTERN)

    errors.add(:token, "must be a valid Linear API key format (lin_api_...)")
  end

  def created_by_belongs_to_same_account
    return if created_by.account_id == account_id

    errors.add(:created_by, "must belong to the same account")
  end
end
