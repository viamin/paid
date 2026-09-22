# frozen_string_literal: true

require "psych"

module AppleVerification
  # Parses and typed-validates `.paid/apple-verification.yml`. Rejects any
  # field, flow operation, or dependency bootstrap system outside the fixed
  # vocabulary with a deterministic diagnostic before any worker is
  # provisioned.
  # @spec APPLE-WORKER-011
  class ConfigurationParser
    CONFIG_PATH = ".paid/apple-verification.yml"
    SUPPORTED_VERSION = 1
    PLATFORMS = AppleVerificationWorkers::PLATFORMS
    SUPPORTED_BOOTSTRAP_SYSTEMS = %w[spm].freeze
    UNSUPPORTED_BOOTSTRAP_SYSTEMS = %w[cocoapods carthage bazel tuist].freeze
    FLOW_OPERATIONS = %w[
      launch_app wait_for_process wait_for_window wait_for_accessibility_id
      tap type select rotate resize wait capture
    ].freeze

    VALID_TOP_LEVEL_KEYS = %w[version profiles].freeze
    VALID_PROFILE_KEYS = %w[platform worker xcode bootstrap tests captures].freeze
    VALID_WORKER_KEYS = %w[xcode simulator].freeze
    VALID_XCODE_KEYS = %w[project workspace scheme test_plan].freeze
    VALID_TESTS_KEYS = %w[required].freeze
    VALID_CAPTURE_KEYS = %w[id required flow].freeze

    ConfigurationError = Class.new(StandardError)
    UnsupportedOperationError = Class.new(ConfigurationError)
    UnsupportedBootstrapSystemError = Class.new(ConfigurationError)

    class << self
      def call(content:)
        new(content:).call
      end
    end

    def initialize(content:)
      @content = content
    end

    def call
      parsed = parse_yaml(@content)
      validate_unknown_keys!("top level", parsed, VALID_TOP_LEVEL_KEYS)
      validate_version!(parsed["version"])
      Configuration.new(version: parsed["version"], profiles: build_profiles(parsed["profiles"]))
    end

    private

    def parse_yaml(content)
      parsed = Psych.safe_load(content.to_s, aliases: false)
      raise ConfigurationError, "#{CONFIG_PATH} must contain a YAML mapping at the top level" unless parsed.is_a?(Hash)

      parsed.deep_stringify_keys
    rescue Psych::DisallowedClass => e
      raise ConfigurationError, "#{CONFIG_PATH} contains unsupported YAML types: #{e.message}"
    rescue Psych::BadAlias => e
      raise ConfigurationError, "#{CONFIG_PATH} must not use YAML anchors or aliases: #{e.message}"
    rescue Psych::SyntaxError => e
      raise ConfigurationError, "invalid YAML in #{CONFIG_PATH}: #{e.message}"
    end

    def validate_version!(version)
      return if version == SUPPORTED_VERSION

      raise ConfigurationError, "#{CONFIG_PATH} version must be #{SUPPORTED_VERSION}, got #{version.inspect}"
    end

    def build_profiles(value)
      unless value.is_a?(Hash) && value.present?
        raise ConfigurationError, "#{CONFIG_PATH} profiles must be a non-empty mapping"
      end

      value.map { |name, attributes| build_profile(name, attributes) }
    end

    def build_profile(name, attributes)
      unless attributes.is_a?(Hash)
        raise ConfigurationError, "profile #{name} must be a mapping"
      end

      validate_unknown_keys!("profile #{name}", attributes, VALID_PROFILE_KEYS)

      Configuration::Profile.new(
        name: name.to_s,
        platform: validate_platform!(name, attributes["platform"]),
        worker: build_worker(name, attributes["worker"]),
        xcode: build_xcode(name, attributes["xcode"]),
        bootstrap: validate_bootstrap!(name, attributes["bootstrap"]),
        tests_required: validate_tests!(name, attributes["tests"]),
        captures: build_captures(name, attributes["captures"])
      )
    end

    def validate_platform!(name, value)
      return value if PLATFORMS.include?(value)

      raise ConfigurationError, "profile #{name} platform must be one of: #{PLATFORMS.join(', ')}"
    end

    def build_worker(name, value)
      return Configuration::WorkerConstraint.new(xcode: nil, simulator: nil) if value.nil?

      unless value.is_a?(Hash)
        raise ConfigurationError, "profile #{name} worker must be a mapping"
      end

      validate_unknown_keys!("profile #{name} worker", value, VALID_WORKER_KEYS)
      Configuration::WorkerConstraint.new(
        xcode: validate_xcode_constraint!(name, value["xcode"]),
        simulator: validate_optional_string!("profile #{name} worker.simulator", value["simulator"])
      )
    end

    # Constraint syntax is validated at parse time so an invalid declaration
    # carries a deterministic diagnostic before any worker is provisioned.
    def validate_xcode_constraint!(name, value)
      return nil if value.nil?

      validate_string_constraint!(name, "xcode", value)
      AppleVerificationWorkers::VersionRequirement.parse(value)
      value
    rescue AppleVerificationWorkers::InvalidVersionConstraint => e
      raise ConfigurationError, "profile #{name} worker.xcode #{e.message}"
    end

    def validate_string_constraint!(name, key, value)
      return value if value.is_a?(String) && value.present?

      raise ConfigurationError, "profile #{name} worker.#{key} must be a non-empty string"
    end

    def build_xcode(name, value)
      unless value.is_a?(Hash)
        raise ConfigurationError, "profile #{name} xcode is required"
      end

      validate_unknown_keys!("profile #{name} xcode", value, VALID_XCODE_KEYS)

      project = validate_optional_string!("profile #{name} xcode.project", value["project"])
      workspace = validate_optional_string!("profile #{name} xcode.workspace", value["workspace"])
      unless [ project, workspace ].compact.size == 1
        raise ConfigurationError, "profile #{name} xcode must declare exactly one of project or workspace"
      end

      scheme = value["scheme"]
      unless scheme.is_a?(String) && scheme.present?
        raise ConfigurationError, "profile #{name} xcode.scheme is required"
      end

      Configuration::XcodeTarget.new(
        project:,
        workspace:,
        scheme:,
        test_plan: validate_optional_string!("profile #{name} xcode.test_plan", value["test_plan"])
      )
    end

    def validate_optional_string!(context, value)
      return nil if value.nil?
      return value if value.is_a?(String) && value.present?

      raise ConfigurationError, "#{context} must be a non-empty string"
    end

    def validate_bootstrap!(name, value)
      return nil if value.nil?

      if UNSUPPORTED_BOOTSTRAP_SYSTEMS.include?(value)
        raise UnsupportedBootstrapSystemError, "profile #{name} declares unsupported bootstrap system #{value}"
      end

      return value if SUPPORTED_BOOTSTRAP_SYSTEMS.include?(value)

      raise ConfigurationError, "profile #{name} bootstrap must be one of: #{SUPPORTED_BOOTSTRAP_SYSTEMS.join(', ')}"
    end

    def validate_tests!(name, value)
      return nil if value.nil?

      unless value.is_a?(Hash)
        raise ConfigurationError, "profile #{name} tests must be a mapping"
      end

      validate_unknown_keys!("profile #{name} tests", value, VALID_TESTS_KEYS)
      required = value.fetch("required", false)
      unless [ true, false ].include?(required)
        raise ConfigurationError, "profile #{name} tests.required must be true or false"
      end

      required
    end

    def build_captures(name, value)
      return [] if value.nil?

      unless value.is_a?(Array)
        raise ConfigurationError, "profile #{name} captures must be an array"
      end

      captures = value.map.with_index { |capture, index| build_capture(name, index, capture) }
      duplicates = captures.group_by(&:id).filter_map { |id, group| id if group.size > 1 }
      raise ConfigurationError, "profile #{name} captures must have unique ids: #{duplicates.join(', ')}" if duplicates.any?

      captures
    end

    def build_capture(profile_name, index, value)
      unless value.is_a?(Hash)
        raise ConfigurationError, "profile #{profile_name} captures[#{index}] must be a mapping"
      end

      validate_unknown_keys!("profile #{profile_name} captures[#{index}]", value, VALID_CAPTURE_KEYS)

      id = value["id"]
      unless id.is_a?(String) && id.present?
        raise ConfigurationError, "profile #{profile_name} captures[#{index}].id is required"
      end

      required = value.fetch("required", false)
      unless [ true, false ].include?(required)
        raise ConfigurationError, "profile #{profile_name} captures[#{index}].required must be true or false"
      end

      Configuration::Capture.new(id:, required:, flow: build_flow(profile_name, id, value["flow"]))
    end

    def build_flow(profile_name, capture_id, value)
      unless value.is_a?(Array) && value.present?
        raise ConfigurationError, "profile #{profile_name} capture #{capture_id} flow must be a non-empty array"
      end

      value.map.with_index { |step, index| build_flow_step(profile_name, capture_id, index, step) }
    end

    def build_flow_step(profile_name, capture_id, index, value)
      unless value.is_a?(Hash) && value.size == 1
        raise ConfigurationError, "profile #{profile_name} capture #{capture_id} flow[#{index}] must be a single-key mapping"
      end

      operation, arguments = value.first
      unless FLOW_OPERATIONS.include?(operation)
        raise UnsupportedOperationError, "profile #{profile_name} capture #{capture_id} flow[#{index}] uses unknown operation #{operation}"
      end

      unless arguments.is_a?(Hash)
        raise ConfigurationError, "profile #{profile_name} capture #{capture_id} flow[#{index}].#{operation} arguments must be a mapping"
      end

      Configuration::FlowStep.new(operation:, arguments:)
    end

    def validate_unknown_keys!(context, hash, allowed_keys)
      extras = hash.keys - allowed_keys
      return if extras.empty?

      raise ConfigurationError, "#{context} contains unknown fields: #{extras.join(', ')}"
    end
  end
end
