# frozen_string_literal: true

class TrackerConfiguration < ApplicationRecord
  has_logidze
  TRACKER_TYPES = %w[github_issues jira linear azure_devops mcp generic_webhook].freeze
  CONFIGURABLE_TYPES = %w[Account User Project].freeze

  belongs_to :configurable, polymorphic: true
  belongs_to :integration_credential, optional: true
  belongs_to :linear_token, optional: true
  belongs_to :created_by, class_name: "User", optional: true

  validates :tracker_type, presence: true, inclusion: { in: TRACKER_TYPES }
  validates :configurable_type, inclusion: { in: CONFIGURABLE_TYPES }
  validates :configurable_id, uniqueness: { scope: :configurable_type,
    message: "already has a tracker configuration" }
  validates :integration_credential, presence: { message: "must exist" }, if: -> { integration_credential_id.present? }
  validates :sync_interval_seconds, numericality: { only_integer: true, greater_than_or_equal_to: 300, less_than_or_equal_to: 86_400 }
  validate :credential_belongs_to_same_account
  validate :credential_is_active, if: -> { integration_credential.present? && integration_credential_id_changed? }
  validate :linear_token_belongs_to_same_account
  validate :linear_token_is_active, if: -> { linear_token.present? && linear_token_id_changed? }

  scope :enabled, -> { where(enabled: true) }

  def account
    case configurable
    when Account then configurable
    when User then configurable.account
    when Project then configurable.account
    end
  end

  def adapter
    IssueTrackers::AdapterFactory.build(self)
  end

  private

  def credential_belongs_to_same_account
    return unless integration_credential.present?

    config_account = account
    return unless config_account

    unless integration_credential.account_id == config_account.id
      errors.add(:integration_credential, "must belong to the same account")
    end
  end

  def credential_is_active
    return if integration_credential.active?

    errors.add(:integration_credential, "must be active (not revoked or expired)")
  end

  def linear_token_belongs_to_same_account
    return if linear_token.nil? || linear_token.account_id == account&.id

    errors.add(:linear_token, "must belong to the same account")
  end

  def linear_token_is_active
    return if linear_token.active?

    errors.add(:linear_token, "must be active (not revoked or expired)")
  end
end
