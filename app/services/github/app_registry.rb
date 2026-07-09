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

    def self.bot_login
      "#{slug}[bot]"
    end

    def self.bot_logins
      [ slug, bot_login ].freeze
    end

    def self.install_url(state: nil)
      url = "https://github.com/apps/#{slug}/installations/new"
      return url if state.blank?

      "#{url}?state=#{state}"
    end

    def self.credentials_dig(key)
      Rails.application.credentials.dig(key).presence
    end
    private_class_method :credentials_dig
  end
end
