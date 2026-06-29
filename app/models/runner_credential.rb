# frozen_string_literal: true

class RunnerCredential < ApplicationRecord
  has_logidze
  AUTH_KINDS = %w[oauth_token api_key signing_token].freeze

  belongs_to :account
  belongs_to :created_by, class_name: "User", optional: true

  encrypts :token

  validates :name, presence: true, uniqueness: { scope: %i[account_id runner_key] }, if: :supports_name_attribute?
  validates :runner_key, presence: true
  validates :runner_key, inclusion: { in: ->(_) { supported_runner_keys }, message: "is not supported" },
    allow_blank: true, if: -> { new_record? || will_save_change_to_runner_key? }
  validates :auth_kind, presence: true, inclusion: { in: AUTH_KINDS }, if: :supports_auth_kind_attribute?
  validates :token, presence: true
  validate :created_by_belongs_to_same_account, if: -> { created_by.present? }

  scope :active, -> {
    relation = where(revoked_at: nil)
    next relation unless supports_expires_at_attribute?

    relation.where("long_lived = true OR expires_at IS NULL OR expires_at > ?", Time.current)
  }
  scope :revoked, -> { where.not(revoked_at: nil) }
  scope :for_runner, ->(runner_key) { where(runner_key: runner_key.to_s) }
  scope :long_lived, -> { where(long_lived: true) }

  def active?
    return revoked_at.nil? unless supports_expires_at_attribute?

    revoked_at.nil? && (long_lived? || expires_at.nil? || expires_at > Time.current)
  end

  def revoked?
    revoked_at.present?
  end

  def expired?
    return false unless supports_expires_at_attribute?

    !revoked? && !long_lived? && expires_at.present? && expires_at <= Time.current
  end

  def revoke!
    update_column(:revoked_at, Time.current)
  end

  def self.supported_runner_keys
    RunnerSupport.supported_runner_keys
  end

  def display_name
    Runner.display_name_for(runner_key)
  end

  private

  def created_by_belongs_to_same_account
    return if created_by.account_id == account_id

    errors.add(:created_by, "must belong to the same account")
  end

  def supports_name_attribute?
    self.class.supports_name_attribute?
  end

  def supports_auth_kind_attribute?
    self.class.supports_auth_kind_attribute?
  end

  def supports_expires_at_attribute?
    self.class.supports_expires_at_attribute?
  end

  def self.supports_name_attribute?
    column_names.include?("name")
  end

  def self.supports_auth_kind_attribute?
    column_names.include?("auth_kind")
  end

  def self.supports_expires_at_attribute?
    column_names.include?("expires_at")
  end
end
