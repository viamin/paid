# frozen_string_literal: true

module Screenshots
  class Configuration < ::Data.define(
    :enabled,
    :driver,
    :base_url,
    :viewport,
    :routes,
    :auth,
    :seed,
    :setup_commands,
    :services,
    :ui_patterns,
    :ui_exclusions
  )
    VALID_DRIVERS = %w[playwright cuprite].freeze
    VALID_AUTH_STRATEGIES = %w[none form token custom].freeze
    DEFAULT_BASE_URL = "http://localhost:3000"
    DEFAULT_UI_PATTERNS = [
      "app/views/**/*",
      "app/javascript/**/*",
      "app/assets/stylesheets/**/*",
      "app/components/**/*"
    ].freeze
    DEFAULT_UI_EXCLUSIONS = [
      "app/views/layouts/mailer/**/*",
      "app/views/pwa/**/*"
    ].freeze

    Viewport = ::Data.define(:width, :height)
    Route = ::Data.define(:path, :name, :requires_auth, :seed_key)
    Auth = ::Data.define(:strategy, :login_path, :fields, :credentials)
    SeedRecord = ::Data.define(:key, :runner, :model, :factory, :attributes)

    class << self
      def from_hash(hash)
        hash ||= {}

        new(
          enabled: hash["enabled"] == true,
          driver: hash.fetch("driver", "playwright"),
          base_url: hash.fetch("base_url", DEFAULT_BASE_URL),
          viewport: viewport_from_hash(hash["viewport"]),
          routes: routes_from_array(hash["routes"]),
          auth: auth_from_hash(hash["auth"]),
          seed: seed_from_array(hash["seed"]),
          setup_commands: string_array(hash["setup_commands"] || hash["setup"]).freeze,
          services: string_array(hash["services"]).freeze,
          ui_patterns: string_array(hash["ui_patterns"], default: DEFAULT_UI_PATTERNS).freeze,
          ui_exclusions: string_array(hash["ui_exclusions"], default: DEFAULT_UI_EXCLUSIONS).freeze
        )
      end

      private

      def viewport_from_hash(hash)
        normalized = hash || {}

        Viewport.new(
          width: normalized.fetch("width", 1280),
          height: normalized.fetch("height", 900)
        )
      end

      def routes_from_array(routes)
        Array(routes).map do |route|
          Route.new(
            path: route["path"],
            name: route["name"],
            requires_auth: route["requires_auth"] == true,
            seed_key: route["seed_key"]
          )
        end.freeze
      end

      def auth_from_hash(hash)
        normalized = hash || {}

        Auth.new(
          strategy: normalized.fetch("strategy", "none"),
          login_path: normalized["login_path"],
          fields: stringify_hash(normalized["fields"]).freeze,
          credentials: stringify_hash(normalized["credentials"]).freeze
        )
      end

      def seed_from_array(seed)
        Array(seed).map do |record|
          SeedRecord.new(
            key: record["key"],
            runner: record["runner"],
            model: record["model"],
            factory: record["factory"],
            attributes: record.except("model", "factory", "key", "runner").deep_stringify_keys.freeze
          )
        end.freeze
      end

      def string_array(value, default: [])
        return default.map(&:dup) if value.nil?

        Array(value).map(&:to_s)
      end

      def stringify_hash(value)
        return {} unless value.is_a?(Hash)

        value.deep_stringify_keys
      end
    end

    def enabled? = enabled == true
    def setup = setup_commands
  end
end
