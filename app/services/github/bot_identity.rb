# frozen_string_literal: true

module Github
  class BotIdentity
    DEFAULT_APP_SLUG = "paid-agents"
    DEFAULT_NAME = "Paid Agent"
    DEFAULT_EMAIL = "agent@paid-agents.com"

    attr_reader :app_slug, :name, :email

    def self.for_git
      new(
        app_slug: configured_app_slug || DEFAULT_APP_SLUG,
        name: configured_name || DEFAULT_NAME,
        email: configured_email || derived_email || DEFAULT_EMAIL
      )
    end

    def self.bot_login
      "#{for_git.app_slug}[bot]"
    end

    def self.configured_app_slug
      ENV["PAID_AGENT_APP_SLUG"].presence || credentials_dig(:paid_agent_app_slug)
    end

    def self.configured_name
      ENV["PAID_AGENT_NAME"].presence || credentials_dig(:paid_agent_name)
    end

    def self.configured_email
      ENV["PAID_AGENT_EMAIL"].presence || credentials_dig(:paid_agent_email)
    end

    def self.derived_email
      slug = configured_app_slug
      return if slug.blank?

      "#{slug}@#{slug}.com"
    end

    def self.credentials_dig(key)
      Rails.application.credentials.dig(key).presence
    end
    private_class_method :credentials_dig, :derived_email

    def initialize(app_slug:, name:, email:)
      @app_slug = app_slug
      @name = name
      @email = email
    end
  end
end
