# frozen_string_literal: true

module Github
  class AppRegistry
    DEFAULT_APP_SLUG = "paid-agents"

    def self.configured?
      app_id.present? && private_key.present? && Github::AppJwt.private_key_parseable?(private_key)
    end

    def self.app_id
      ENV["PAID_AGENT_APP_ID"].presence || credentials_dig(:paid_agent_app_id)
    end

    def self.slug
      ENV["PAID_AGENT_APP_SLUG"].presence || credentials_dig(:paid_agent_app_slug) || DEFAULT_APP_SLUG
    end

    def self.private_key
      ENV["PAID_AGENT_APP_PRIVATE_KEY"].presence || credentials_dig(:paid_agent_app_private_key)
    end

    def self.webhook_secret
      ENV["PAID_AGENT_APP_WEBHOOK_SECRET"].presence || credentials_dig(:paid_agent_app_webhook_secret)
    end

    def self.bot_login
      "#{slug}[bot]"
    end

    def self.bot_logins
      [ slug, bot_login ].freeze
    end

    def self.install_url(state: nil)
      uri = URI::HTTPS.build(host: "github.com", path: install_path)
      return uri.to_s if state.blank?

      "#{uri}?#{URI.encode_www_form(state: state)}"
    end

    def self.credentials_dig(key)
      Rails.application.credentials.dig(key).presence
    end

    def self.install_path
      "/apps/#{ERB::Util.url_encode(slug.to_s)}/installations/new"
    end

    private_class_method :credentials_dig
    private_class_method :install_path
  end
end
