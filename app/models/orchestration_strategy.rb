# frozen_string_literal: true

class OrchestrationStrategy < ApplicationRecord
  has_logidze
  STRATEGY_TYPES = %w[
    review_settings
    quality_gate
    execution_timeouts
    retry_policies
    agent_settings
    feature_orchestration
    provider_resolution
  ].freeze

  belongs_to :account, optional: true

  validates :strategy_type, presence: true, inclusion: { in: STRATEGY_TYPES }
  validates :name, presence: true
  validates :version, presence: true, numericality: { only_integer: true, greater_than: 0 }
  validates :configuration, presence: true
  validate :configuration_is_object

  scope :active, -> { where(active: true) }
  scope :system_defaults, -> { where(account_id: nil) }
  scope :for_account, ->(account) { where(account: account) }
  scope :by_type, ->(type) { where(strategy_type: type) }

  def self.active_for(strategy_type, account: nil)
    if account
      for_account(account).by_type(strategy_type).active.order(version: :desc).first ||
        system_defaults.by_type(strategy_type).active.order(version: :desc).first
    else
      system_defaults.by_type(strategy_type).active.order(version: :desc).first
    end
  end

  def config_value(*keys)
    keys.reduce(configuration) do |hash, key|
      return nil unless hash.is_a?(Hash)

      hash[key.to_s]
    end
  end

  private

  def configuration_is_object
    return if configuration.is_a?(Hash)

    errors.add(:configuration, "must be a JSON object")
  end
end
