# frozen_string_literal: true

module AppleVerification
  module GuestManifest
    # Builds the closed guest protocol from workflow content bound to its
    # approved digest; callers cannot provide ad-hoc operations.
    # @spec APPLE-WORKER-013
    # @spec APPLE-RESULT-006
    class Build
      def self.call(attempt:)
        new(attempt:).call
      end

      def initialize(attempt:)
        @attempt = attempt
      end

      def call
        operations = [ materialize_source, *profile_operations, export_artifacts ]
        GuestProtocol.validate!("version" => GuestProtocol::VERSION, "operations" => operations)
        operations
      rescue GuestProtocol::InvalidManifestError, GuestProtocol::UnsupportedOperationError => error
        raise ConfigurationParser::ConfigurationError, error.message
      end

      private

      def materialize_source
        operation("materialize_source", { "digest" => @attempt.source_digest })
      end

      def profile_operations
        selected_profiles.flat_map { |profile| operations_for(profile) }
      end

      def configuration
        @configuration ||= ConfigurationParser.call(content: @attempt.apple_verification_workflow_revision.configuration_content)
      end

      def operations_for(profile)
        [ *package_operations(profile), build_operation(profile), *test_operations(profile), *simulator_operations(profile), *capture_operations(profile) ]
      end

      def selected_profiles
        return configuration.profiles unless requested_capture

        profiles = configuration.profiles.select { |profile| selected_captures(profile).any? }
        raise ConfigurationParser::ConfigurationError, "requested capture #{requested_capture.inspect} is not declared" if profiles.empty?

        profiles
      end

      def package_operations(profile)
        [ operation("resolve_swift_packages") ] if profile.bootstrap == "spm"
      end

      def build_operation(profile)
        operation("build", scheme_payload(profile))
      end

      def test_operations(profile)
        [ operation("test", test_payload(profile), required: profile.tests_required) ] unless profile.tests_required.nil?
      end

      def simulator_operations(profile)
        return [] unless profile.platform.in?(%w[ios ipados]) && profile.captures.any?

        required = selected_captures(profile).any?(&:required)
        [ operation("boot_simulator", { "destination" => profile.worker.simulator }, required:), operation("install_app", { "bundle_id" => profile.xcode.bundle_id }, required:) ]
      end

      def capture_operations(profile)
        selected_captures(profile).flat_map { |capture| capture.flow.map { |step| flow_operation(profile, capture, step) } }
      end

      def selected_captures(profile)
        return profile.captures unless requested_capture

        profile.captures.select { |capture| "#{profile.name}.#{capture.id}" == requested_capture }
      end

      def requested_capture
        @requested_capture ||= @attempt.requested_capture.presence
      end

      def flow_operation(profile, capture, step)
        return operation("launch_app", { "bundle_id" => profile.xcode.bundle_id }, required: capture.required) if step.operation == "launch_app"
        return operation("capture", capture_payload(profile, capture, step), required: capture.required) if step.operation == "capture"

        operation("ui_action", ui_action_payload(step), required: capture.required)
      end

      def scheme_payload(profile)
        {
          "project" => profile.xcode.project,
          "workspace" => profile.xcode.workspace,
          "scheme" => profile.xcode.scheme
        }.compact
      end

      def test_payload(profile)
        scheme_payload(profile).merge("test_plan" => profile.xcode.test_plan).compact
      end

      def capture_payload(profile, capture, step)
        {
          "platform" => profile.platform,
          "target" => profile.platform == "macos" ? "app_window" : "simulator_screen",
          "name" => step.arguments["name"] || capture.id
        }
      end

      def ui_action_payload(step)
        { "action" => ui_action_name(step.operation) }.merge(ui_action_arguments(step))
      end

      def ui_action_name(operation_name)
        { "rotate" => "rotate_simulator", "resize" => "resize_window" }.fetch(operation_name, operation_name)
      end

      def ui_action_arguments(step)
        step.arguments.deep_stringify_keys.transform_keys { |key| key == "id" ? "accessibility_id" : key }
      end

      def export_artifacts
        operation("export_artifacts")
      end

      def operation(type, payload = {}, required: true)
        { "type" => type, "payload" => payload, "required" => required }
      end
    end
  end
end
