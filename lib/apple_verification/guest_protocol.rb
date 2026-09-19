# frozen_string_literal: true

module AppleVerification
  # @spec APPLE-VERIFY-003
  # @spec APPLE-VERIFY-004
  class GuestProtocol
    VERSION = 1
    OPERATION_TYPES = %w[materialize_source resolve_swift_packages inspect_xcode build test boot_simulator install_app launch_app ui_action capture collect_diagnostics export_artifacts].freeze
    SHELL_FIELDS = %w[command shell script executable].freeze
    UI_ACTIONS = %w[tap type select wait_for_accessibility_id rotate_simulator resize_window].freeze
    CAPTURE_STAGES = %w[launch readiness action selection export].freeze

    UnsupportedVersionError = Class.new(ArgumentError)
    UnsupportedOperationError = Class.new(ArgumentError)
    InvalidManifestError = Class.new(ArgumentError)
    ArbitraryShellError = Class.new(ArgumentError)

    class << self
      def validate!(manifest)
        validate_root!(manifest)
        manifest.fetch("operations").each { |operation| validate_operation!(operation) }
        manifest
      end

      def capture_failure(platform:, target:, stage:, message:)
        validate_capture!(platform, target, stage)
        { "status" => "failed", "failure_class" => "capture_#{stage}", "platform" => platform, "target" => target, "message" => message.to_s }
      end

      private

      def validate_root!(manifest)
        raise InvalidManifestError, "manifest must be an object" unless manifest.is_a?(Hash)
        raise UnsupportedVersionError, "unsupported guest protocol version" unless manifest["version"] == VERSION
        raise InvalidManifestError, "operations must be an array" unless manifest["operations"].is_a?(Array)
      end

      def validate_operation!(operation)
        raise InvalidManifestError, "operation must be an object" unless operation.is_a?(Hash)

        type = operation["type"]
        raise UnsupportedOperationError, "unsupported guest operation #{type.inspect}" unless OPERATION_TYPES.include?(type)
        validate_payload!(operation["payload"])
        validate_ui_action!(operation.fetch("payload")) if type == "ui_action"
        validate_capture_payload!(operation.fetch("payload")) if type == "capture"
      end

      def validate_payload!(payload)
        raise InvalidManifestError, "operation payload must be an object" unless payload.is_a?(Hash)
        raise ArbitraryShellError, "guest operations cannot contain shell text" if shell_field?(payload)
      end

      def shell_field?(value)
        case value
        when Hash
          value.any? { |key, nested| SHELL_FIELDS.include?(key.to_s) || shell_field?(nested) }
        when Array
          value.any? { |item| shell_field?(item) }
        else
          false
        end
      end

      def validate_ui_action!(payload)
        raise InvalidManifestError, "unsupported declarative UI action" unless UI_ACTIONS.include?(payload["action"])
      end

      def validate_capture_payload!(payload)
        validate_capture!(payload["platform"], payload["target"], "export")
      end

      def validate_capture!(platform, target, stage)
        valid_target = (platform == "ios" || platform == "ipados") && target == "simulator_screen" || platform == "macos" && target == "app_window"
        raise InvalidManifestError, "unsupported capture platform or target" unless valid_target
        raise InvalidManifestError, "unsupported capture failure stage" unless CAPTURE_STAGES.include?(stage)
      end
    end
  end
end
