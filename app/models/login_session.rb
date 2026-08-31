# frozen_string_literal: true

class LoginSession < ApplicationRecord
  SESSION_TTL = 15.minutes
  STATUSES = %w[starting awaiting_code awaiting_authorization polling authorizing completed failed].freeze
  PROVIDERS = %w[claude codex].freeze

  belongs_to :account
  belongs_to :created_by, class_name: "User"
  belongs_to :integration_credential, optional: true
  belongs_to :runner_credential, optional: true

  encrypts :device_code

  validates :external_id, presence: true, uniqueness: true
  validates :session_token, presence: true, uniqueness: true
  validates :credential_name, presence: true, length: { maximum: 100 }
  validates :status, presence: true, inclusion: { in: STATUSES }
  validates :provider, presence: true, inclusion: { in: PROVIDERS }
  validate :created_by_belongs_to_account
  validate :integration_credential_belongs_to_account, if: -> { integration_credential.present? }
  validate :runner_credential_belongs_to_account, if: -> { runner_credential.present? }

  before_validation :assign_defaults, on: :create

  scope :recent, -> { order(created_at: :desc) }
  scope :by_provider, ->(provider) { where(provider: provider) }

  def target_runner_key
    metadata.to_h["target_runner_key"].presence || provider
  end

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

  PROVIDERS.each do |value|
    define_method("#{value}?") do
      provider == value
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
    self.poll_interval ||= 5 if provider == "codex"
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

  def runner_credential_belongs_to_account
    return if runner_credential.account_id == account_id

    errors.add(:runner_credential, "must belong to the same account")
  end
end
