# frozen_string_literal: true

class ClaudeLoginSession < LoginSession
  self.table_name = "login_sessions"

  scope :filtered_by_provider, -> { where(provider: "claude") }

  def self.all
    super.filtered_by_provider
  end

  def self.where(*args, **kwargs)
    super(*args, **kwargs).filtered_by_provider
  end

  validates :provider, inclusion: { in: %w[claude] }, allow_nil: true

  before_validation :set_claude_provider

  private

  def set_claude_provider
    self.provider = "claude" if provider.blank?
  end
end
