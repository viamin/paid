# frozen_string_literal: true

require "base64"
require "psych"

module Screenshots
  class ConfigParser
    CONFIG_PATH = ".paid/screenshots.yml"
    RUNNER_REFERENCE_PATTERN = /\AScreenshots::SeedData::[A-Z]\w*(?:::[A-Z]\w*)*\.call\z/
    VALID_TOP_LEVEL_KEYS = %w[
      driver
      enabled
      framework
      base_url
      viewport
      routes
      auth
      seed
      setup_commands
      setup
      services
      ui_patterns
      ui_exclusions
    ].freeze
    VALID_PROJECT_TOP_LEVEL_KEYS = %w[
      config_path
      auto_capture
      service_dependencies
      detection
    ].freeze
    VALID_ROUTE_KEYS = %w[path name requires_auth seed_key].freeze
    VALID_AUTH_KEYS = %w[strategy login_path fields credentials].freeze
    VALID_VIEWPORT_KEYS = %w[width height].freeze
    class << self
      def call(project: nil, repo_path: nil, blob: nil, content: nil)
        new(project:, repo_path:, blob:, content:).call
      end

      def ui_detection_overrides(project: nil, repo_path: nil, blob: nil, content: nil)
        new(project:, repo_path:, blob:, content:).ui_detection_overrides
      end

      def from_repo_path(repo_path, project: nil)
        call(project:, repo_path:)
      end

      def from_blob(blob, project: nil)
        call(project:, blob:)
      end

      # Validates a partial settings hash (e.g. DB-stored project settings where
      # routes are not required). Raises ConfigError on invalid nested values.
      def validate_partial!(settings)
        new.validate_partial!(settings)
      end
    end

    def initialize(project: nil, repo_path: nil, blob: nil, content: nil)
      @project = project
      @repo_path = repo_path
      @blob = blob
      @content = content
    end

    def call
      file_settings = parse_content(raw_content)
      validate_root!(file_settings)

      Screenshots::Configuration.from_hash(merged_settings(file_settings)).freeze
    end

    def ui_detection_overrides
      file_settings = if content.present? || blob.present? || (repo_path.present? && File.exist?(config_path))
        parse_content(raw_content)
      else
        {}
      end
      validate_partial!(file_settings)

      merged = merged_settings(file_settings)
      explicit_settings = explicit_project_settings.merge(file_settings)

      {}.tap do |overrides|
        overrides[:framework] = merged["framework"]&.to_sym if explicit_settings.key?("framework")
        overrides[:patterns] = merged["ui_patterns"] if explicit_settings.key?("ui_patterns")
        overrides[:exclusions] = merged["ui_exclusions"] if explicit_settings.key?("ui_exclusions")
      end
    end

    def validate_partial!(settings)
      validate_unknown_keys!("top-level", settings, VALID_TOP_LEVEL_KEYS + VALID_PROJECT_TOP_LEVEL_KEYS)

      validate_driver!(settings["driver"]) if settings.key?("driver")
      validate_enabled!(settings["enabled"]) if settings.key?("enabled")
      validate_framework!(settings["framework"]) if settings.key?("framework")
      validate_base_url!(settings["base_url"]) if settings.key?("base_url")
      validate_viewport!(settings["viewport"]) if settings.key?("viewport")
      validate_routes_shape!(settings["routes"]) if settings.key?("routes")
      validate_auth!(settings["auth"]) if settings.key?("auth")
      validate_seed!(settings["seed"]) if settings.key?("seed")
      validate_string_array!("setup", settings["setup"]) if settings.key?("setup")
      validate_string_array!("setup_commands", settings["setup_commands"]) if settings.key?("setup_commands")
      validate_string_array!("services", settings["services"]) if settings.key?("services")
      validate_config_path!(settings["config_path"]) if settings.key?("config_path")
      validate_auto_capture!(settings["auto_capture"]) if settings.key?("auto_capture")
      validate_string_array!("service_dependencies", settings["service_dependencies"]) if settings.key?("service_dependencies")
      validate_detection!(settings["detection"]) if settings.key?("detection")
      validate_globs!("ui_patterns", settings["ui_patterns"]) if settings.key?("ui_patterns")
      validate_globs!("ui_exclusions", settings["ui_exclusions"]) if settings.key?("ui_exclusions")
    end

    private

    attr_reader :project, :repo_path, :blob, :content

    def raw_content
      return content if content.present?
      return decode_blob(blob) if blob.present?

      path = config_path
      raise ConfigError, "Missing #{config_path_label} in #{repo_path}" unless File.exist?(path)

      File.read(path)
    rescue Errno::ENOENT => e
      raise ConfigError, "Unable to read #{config_path_label}: #{e.message}"
    end

    def config_path
      Pathname(repo_path).join(config_path_label)
    end

    def config_path_label
      explicit_project_settings["config_path"].presence || CONFIG_PATH
    end

    def decode_blob(value)
      return value if value.is_a?(String)
      return Base64.decode64(value.content.to_s) if value.respond_to?(:content)

      raise ConfigError, "GitHub blob must be a YAML string or a blob object with content"
    end

    def parse_content(value)
      parsed = Psych.safe_load(value, aliases: false)
      return {} if parsed.nil?

      unless parsed.is_a?(Hash)
        raise ConfigError, "#{config_path_label} must contain a YAML mapping at the top level"
      end

      parsed.deep_stringify_keys
    rescue Psych::DisallowedClass => e
      raise ConfigError, "#{config_path_label} contains unsupported YAML types (e.g. symbols): #{e.message}"
    rescue Psych::SyntaxError => e
      raise ConfigError, "Invalid YAML in #{config_path_label}: #{e.message}"
    end

    def merged_settings(file_settings)
      db_settings = project&.effective_screenshot_settings || {}
      explicit_db_settings = explicit_project_settings
      merged = db_settings.deep_merge(file_settings)

      %w[routes auth seed setup setup_commands].each do |key|
        merged[key] = file_settings[key] if file_settings.key?(key)
      end

      if file_settings.key?("setup") || file_settings.key?("setup_commands")
        merged["setup"] = file_settings["setup"] if file_settings.key?("setup")
        merged["setup_commands"] = file_settings["setup_commands"] if file_settings.key?("setup_commands")
        merged.delete("setup_commands") if file_settings.key?("setup") && !file_settings.key?("setup_commands")
        merged.delete("setup") if file_settings.key?("setup_commands") && !file_settings.key?("setup")
      end

      %w[enabled driver].each do |key|
        merged[key] = explicit_db_settings[key] if explicit_db_settings.key?(key)
      end

      merged
    end

    def explicit_project_settings
      settings = project&.screenshot_settings
      return {} unless settings.is_a?(Hash)

      settings.deep_stringify_keys
    end

    def validate_root!(settings)
      validate_partial!(settings)
      validate_routes!(settings["routes"])
    end

    def validate_unknown_keys!(context, hash, allowed_keys)
      extras = hash.keys - allowed_keys
      return if extras.empty?

      raise ConfigError, "#{context} contains unknown keys: #{extras.join(', ')}"
    end

    def validate_driver!(value)
      return if value.in?(Configuration::VALID_DRIVERS)

      raise ConfigError, "driver must be one of: #{Configuration::VALID_DRIVERS.join(', ')}"
    end

    def validate_enabled!(value)
      return if value == true || value == false

      raise ConfigError, "enabled must be true or false"
    end

    def validate_framework!(value)
      framework = value.is_a?(String) || value.is_a?(Symbol) ? value.to_sym : nil
      return if framework&.in?(FrameworkPatterns::REGISTRY.keys)

      raise ConfigError, "framework must be one of: #{FrameworkPatterns::REGISTRY.keys.join(', ')}"
    end

    def validate_base_url!(value)
      return if value.is_a?(String) && value.present?

      raise ConfigError, "base_url must be a non-blank string"
    end

    def validate_config_path!(value)
      return if value.is_a?(String) && value.present?

      raise ConfigError, "config_path must be a non-blank string"
    end

    def validate_auto_capture!(value)
      return if value == true || value == false

      raise ConfigError, "auto_capture must be true or false"
    end

    def validate_detection!(value)
      return if value.is_a?(Hash)

      raise ConfigError, "detection must be a mapping"
    end

    def validate_viewport!(value)
      unless value.is_a?(Hash)
        raise ConfigError, "viewport must be a mapping with width and height"
      end

      validate_unknown_keys!("viewport", value, VALID_VIEWPORT_KEYS)

      %w[width height].each do |key|
        next unless value.key?(key)

        viewport_value = value[key]
        next if viewport_value.is_a?(Integer) && viewport_value.positive?

        raise ConfigError, "viewport.#{key} must be a positive integer"
      end
    end

    def validate_routes!(value)
      unless value.is_a?(Array) && value.any?
        raise ConfigError, "routes must be a non-empty array"
      end

      validate_routes_shape!(value)
    end

    def validate_routes_shape!(value)
      return unless value.is_a?(Array)

      value.each_with_index do |route, index|
        unless route.is_a?(Hash)
          raise ConfigError, "routes[#{index}] must be a mapping"
        end

        validate_unknown_keys!("routes[#{index}]", route, VALID_ROUTE_KEYS)

        %w[path name].each do |key|
          next if route[key].is_a?(String) && route[key].present?

          raise ConfigError, "routes[#{index}].#{key} is required"
        end

        if route.key?("requires_auth") && ![ true, false ].include?(route["requires_auth"])
          raise ConfigError, "routes[#{index}].requires_auth must be true or false"
        end

        if route.key?("seed_key") && !(route["seed_key"].is_a?(String) && route["seed_key"].present?)
          raise ConfigError, "routes[#{index}].seed_key must be a non-blank string"
        end
      end
    end

    def validate_auth!(value)
      unless value.is_a?(Hash)
        raise ConfigError, "auth must be a mapping"
      end

      validate_unknown_keys!("auth", value, VALID_AUTH_KEYS)

      strategy = value.fetch("strategy", "none")
      unless strategy.in?(Configuration::VALID_AUTH_STRATEGIES)
        raise ConfigError, "auth.strategy must be one of: #{Configuration::VALID_AUTH_STRATEGIES.join(', ')}"
      end

      if value.key?("login_path") && !(value["login_path"].is_a?(String) && value["login_path"].present?)
        raise ConfigError, "auth.login_path must be a non-blank string"
      end

      %w[fields credentials].each do |key|
        next unless value.key?(key)
        next if value[key].is_a?(Hash)

        raise ConfigError, "auth.#{key} must be a mapping"
      end

      return unless strategy == "form"

      fields = value["fields"]
      unless fields.is_a?(Hash)
        raise ConfigError, "auth.fields is required when auth.strategy is form"
      end

      %w[email password submit].each do |key|
        next if fields[key].is_a?(String) && fields[key].present?

        raise ConfigError, "auth.fields.#{key} is required when auth.strategy is form"
      end
    end

    def validate_seed!(value)
      unless value.is_a?(Array)
        raise ConfigError, "seed must be an array"
      end

      value.each_with_index do |record, index|
        unless record.is_a?(Hash)
          raise ConfigError, "seed[#{index}] must be a mapping"
        end

        unless record["key"].is_a?(String) && record["key"].present?
          raise ConfigError, "seed[#{index}].key is required"
        end

        if record["runner"].present?
          unless record["runner"].is_a?(String) && record["runner"].match?(RUNNER_REFERENCE_PATTERN)
            raise ConfigError,
              "seed[#{index}].runner must reference Screenshots::SeedData::<Runner>.call"
          end

          next
        end

        %w[model factory].each do |key|
          next if record[key].is_a?(String) && record[key].present?

          raise ConfigError, "seed[#{index}].#{key} is required"
        end
      end
    end

    def validate_string_array!(name, value)
      unless value.is_a?(Array)
        raise ConfigError, "#{name} must be an array"
      end

      value.each_with_index do |item, index|
        next if item.is_a?(String) && item.present?

        raise ConfigError, "#{name}[#{index}] must be a non-blank string"
      end
    end

    def validate_globs!(name, value)
      validate_string_array!(name, value)

      value.each_with_index do |pattern, index|
        next if valid_glob_pattern?(pattern)

        raise ConfigError, "#{name}[#{index}] must be a valid glob pattern"
      end
    end

    def valid_glob_pattern?(pattern)
      return false if pattern.include?("\0")

      balanced_glob?(pattern, "{", "}") && balanced_glob?(pattern, "[", "]")
    end

    def balanced_glob?(pattern, open_char, close_char)
      balance = 0

      pattern.each_char do |char|
        balance += 1 if char == open_char
        balance -= 1 if char == close_char
        return false if balance.negative?
      end

      balance.zero?
    end
  end
end
