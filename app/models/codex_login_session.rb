# frozen_string_literal: true

class CodexLoginSession < LoginSession
  self.table_name = "login_sessions"

  scope :filtered_by_provider, -> { where(provider: "codex") }

  def self.all
    super.filtered_by_provider
  end

  def self.where(*args, **kwargs)
    super(*args, **kwargs).filtered_by_provider
  end

  validates :provider, inclusion: { in: %w[codex] }, allow_nil: true

  before_validation :set_codex_provider

  private

  def set_codex_provider
    self.provider = "codex" if provider.blank?
  end
end
