# frozen_string_literal: true

class Provider < ApplicationRecord
  SUPPORTED_PROVIDER_KEYS = %w[claude cursor aider].freeze

  belongs_to :user

  scope :for_agent_runs, -> { where(enabled_for_agent_runs: true) }
  scope :for_fallback, -> { where(enabled_for_fallback: true) }
  scope :ordered, -> { order(:provider_key) }

  validates :provider_key, presence: true, inclusion: { in: SUPPORTED_PROVIDER_KEYS }, length: { maximum: 50 }
  validates :provider_key, uniqueness: { scope: :user_id }

  validate :must_keep_at_least_one_agent_run_provider

  before_destroy :prevent_destroying_last_agent_run_provider

  def self.ensure_default_for(user)
    user.providers.find_or_create_by!(provider_key: "claude")
  rescue ActiveRecord::RecordNotUnique
    user.providers.find_by!(provider_key: "claude")
  end

  private

  def must_keep_at_least_one_agent_run_provider
    return unless user
    return unless will_save_change_to_enabled_for_agent_runs?(from: true, to: false)

    return if user.providers.where.not(id: id).for_agent_runs.exists?

    errors.add(:enabled_for_agent_runs, "must keep at least one provider enabled for agent runs")
  end

  def prevent_destroying_last_agent_run_provider
    return unless enabled_for_agent_runs?
    return if user.providers.where.not(id: id).for_agent_runs.exists?

    errors.add(:base, "Cannot delete the last provider enabled for agent runs")
    throw(:abort)
  end
end
