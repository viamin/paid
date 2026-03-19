# frozen_string_literal: true

class Provider < ApplicationRecord
  belongs_to :user

  scope :for_agent_runs, -> { where(enabled_for_agent_runs: true) }
  scope :for_fallback, -> { where(enabled_for_fallback: true) }
  scope :ordered, -> { order(:provider_key) }

  validates :provider_key, presence: true, inclusion: { in: ->(_) { supported_provider_keys } }, length: { maximum: 50 }
  validates :provider_key, uniqueness: { scope: :user_id }

  validate :must_keep_at_least_one_agent_run_provider
  validate :default_provider_must_remain_enabled_for_agent_runs

  before_destroy :prevent_destroying_last_agent_run_provider
  before_destroy :prevent_destroying_default_provider

  # Returns the provider key that must always exist and remain enabled for
  # agent runs. Prefers "claude" when container-executable, otherwise falls
  # back to the first available container-executable provider.
  def self.default_provider_key
    executable_keys = ProviderSupport.container_executable_provider_keys
    key = executable_keys.include?("claude") ? "claude" : executable_keys.first
    raise "No container-executable providers available" unless key

    key
  end

  def self.ensure_default_for(user)
    user.providers.find_or_create_by!(provider_key: default_provider_key)
  rescue ActiveRecord::RecordNotUnique
    user.providers.find_by!(provider_key: default_provider_key)
  end

  def self.display_name(provider_key)
    provider = AgentHarness.provider(ProviderSupport.harness_provider_key_for(provider_key).to_sym)

    if provider.respond_to?(:display_name)
      provider.display_name
    else
      provider_key.to_s.titleize
    end
  rescue AgentHarness::ConfigurationError
    provider_key.to_s.titleize
  end

  def self.supported_provider_keys
    ProviderSupport.supported_provider_keys
  end

  def self.supported_provider_key?(provider_key)
    ProviderSupport.supported_provider_key?(provider_key)
  end

  def self.harness_provider_key_for(provider_key)
    ProviderSupport.harness_provider_key_for(provider_key)
  end

  def self.provider_key_for_agent_type(agent_type)
    ProviderSupport.provider_key_for_agent_type(agent_type)
  end

  def self.agent_type_for(provider_key)
    ProviderSupport.agent_type_for(provider_key)
  end

  private

  def must_keep_at_least_one_agent_run_provider
    return unless user
    return unless will_save_change_to_enabled_for_agent_runs?(from: true, to: false)

    return if user.providers.where.not(id: id).for_agent_runs.exists?

    errors.add(:enabled_for_agent_runs, "must keep at least one provider enabled for agent runs")
  end

  def prevent_destroying_last_agent_run_provider
    return if destroyed_by_association.present?
    return unless enabled_for_agent_runs?
    return if user.providers.where.not(id: id).for_agent_runs.exists?

    errors.add(:base, "Cannot delete the last provider enabled for agent runs")
    throw(:abort)
  end

  def default_provider_must_remain_enabled_for_agent_runs
    return unless provider_key == self.class.default_provider_key
    return unless will_save_change_to_enabled_for_agent_runs?(to: false)

    errors.add(:enabled_for_agent_runs,
      "#{Provider.display_name(self.class.default_provider_key)} must remain enabled for agent runs")
  end

  def prevent_destroying_default_provider
    return if destroyed_by_association.present?
    return unless provider_key == self.class.default_provider_key

    errors.add(:base, "Cannot delete the #{Provider.display_name(self.class.default_provider_key)} provider")
    throw(:abort)
  end
end
