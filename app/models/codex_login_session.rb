# frozen_string_literal: true

class CodexLoginSession < LoginSession
  self.table_name = "login_sessions"

  def self.policy_class
    LoginSessionPolicy
  end

  default_scope { where(provider: "codex") }

  validates :provider, inclusion: { in: %w[codex] }, allow_nil: true

  before_validation :set_codex_provider

  private

  def set_codex_provider
    self.provider = "codex" if provider.blank?
  end
end
