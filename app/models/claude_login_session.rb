# frozen_string_literal: true

class ClaudeLoginSession < ApplicationRecord
  SESSION_TTL = 15.minutes
  STATUSES = %w[starting awaiting_code authorizing completed failed].freeze

  belongs_to :account
  belongs_to :created_by, class_name: "User"
  belongs_to :integration_credential, optional: true

  validates :external_id, presence: true, uniqueness: true
  validates :session_token, presence: true, uniqueness: true
  validates :credential_name, presence: true, length: { maximum: 100 }
  validates :status, presence: true, inclusion: { in: STATUSES }
  validate :created_by_belongs_to_account
  validate :integration_credential_belongs_to_account, if: -> { integration_credential.present? }

  before_validation :assign_defaults, on: :create

  scope :recent, -> { order(created_at: :desc) }

  def expired?
    !terminal? && expires_at.present? && expires_at <= Time.current
  end

  def terminal?
    completed? || failed?
  end

  STATUSES.each do |value|
    define_method("#{value}?") do
      status == value
    end
  end

  def fail!(message)
    update!(
      status: "failed",
      error_message: message,
      failed_at: Time.current
    )
  end

  private

  def assign_defaults
    self.external_id ||= SecureRandom.uuid
    self.session_token ||= SecureRandom.hex(32)
    self.status ||= "starting"
    self.expires_at ||= SESSION_TTL.from_now
  end

  def created_by_belongs_to_account
    return if created_by.blank? || created_by.account_id == account_id

    errors.add(:created_by, "must belong to the same account")
  end

  def integration_credential_belongs_to_account
    return if integration_credential.account_id == account_id

    errors.add(:integration_credential, "must belong to the same account")
  end
end
