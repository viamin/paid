# frozen_string_literal: true

class ClaudeLoginSession < LoginSession
  self.table_name = "login_sessions"

  def self.policy_class
    LoginSessionPolicy
  end

  default_scope { where(provider: "claude") }

  validates :provider, inclusion: { in: %w[claude] }, allow_nil: true

  before_validation :set_claude_provider

  private

  def set_claude_provider
    self.provider = "claude" if provider.blank?
  end
end
