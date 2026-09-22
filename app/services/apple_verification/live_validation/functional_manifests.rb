# frozen_string_literal: true

module AppleVerification
  module LiveValidation
    # Builds the closed-protocol guest manifest each functional scenario
    # dispatches. Values are defaults aligned with the RDR-068 configuration
    # example; the CLI can override them through the runner config once a
    # live host publishes its own targets.
    # @spec APPLE-LIVE-002
    module FunctionalManifests
      IOS_TARGETS = {
        "functional-smoke-ios-app" => {
          scheme: "SmokeApp", destination: "iPhone 17", bundle_id: "dev.paid.smokeapp",
          accessibility_id: "main-screen", capture_name: "initial-screen"
        },
        "functional-colormatching-ios" => {
          scheme: "ColorMatchingLPS", destination: "iPhone 17", bundle_id: "dev.viamin.colormatchinglps",
          accessibility_id: "main-screen", capture_name: "initial-screen"
        }
      }.freeze
      MACOS_TARGET = {
        "functional-macos-gui-app" => {
          scheme: "ExampleMac", bundle_id: "dev.paid.examplemac",
          accessibility_id: "main-window", capture_name: "main-window"
        }
      }.freeze
      IOS_CAPTURE = { "platform" => "ios", "target" => "simulator_screen" }.freeze
      MACOS_CAPTURE = { "platform" => "macos", "target" => "app_window" }.freeze

      module_function

      def for(scenario_id, source_digest:)
        if IOS_TARGETS.key?(scenario_id)
          ios_manifest(IOS_TARGETS.fetch(scenario_id), source_digest)
        elsif MACOS_TARGET.key?(scenario_id)
          macos_manifest(MACOS_TARGET.fetch(scenario_id), source_digest)
        else
          raise ArgumentError, "unknown functional scenario: #{scenario_id}"
        end.then { |manifest| AppleVerification::GuestProtocol.validate!(manifest) }
      end

      def ios_manifest(target, source_digest)
        operations = [
          { "type" => "materialize_source", "payload" => { "digest" => source_digest } },
          { "type" => "resolve_swift_packages", "payload" => {} },
          { "type" => "inspect_xcode", "payload" => { "scheme" => target.fetch(:scheme) } },
          { "type" => "build", "payload" => { "scheme" => target.fetch(:scheme) } },
          { "type" => "test", "payload" => { "scheme" => target.fetch(:scheme) } },
          { "type" => "boot_simulator", "payload" => { "destination" => target.fetch(:destination) } },
          { "type" => "install_app", "payload" => { "bundle_id" => target.fetch(:bundle_id) } },
          { "type" => "launch_app", "payload" => { "bundle_id" => target.fetch(:bundle_id) } },
          readiness_action(target),
          capture_operation(IOS_CAPTURE, target),
          { "type" => "export_artifacts", "payload" => {} }
        ]
        { "version" => AppleVerification::GuestProtocol::VERSION, "operations" => operations }
      end

      def macos_manifest(target, source_digest)
        operations = [
          { "type" => "materialize_source", "payload" => { "digest" => source_digest } },
          { "type" => "resolve_swift_packages", "payload" => {} },
          { "type" => "inspect_xcode", "payload" => { "scheme" => target.fetch(:scheme) } },
          { "type" => "build", "payload" => { "scheme" => target.fetch(:scheme) } },
          { "type" => "test", "payload" => { "scheme" => target.fetch(:scheme) } },
          { "type" => "launch_app", "payload" => { "bundle_id" => target.fetch(:bundle_id) } },
          readiness_action(target),
          capture_operation(MACOS_CAPTURE, target),
          { "type" => "export_artifacts", "payload" => {} }
        ]
        { "version" => AppleVerification::GuestProtocol::VERSION, "operations" => operations }
      end

      def readiness_action(target)
        { "type" => "ui_action", "payload" => { "action" => "wait_for_accessibility_id",
                                                 "accessibility_id" => target.fetch(:accessibility_id) } }
      end

      def capture_operation(capture, target)
        { "type" => "capture", "payload" => capture.merge("name" => target.fetch(:capture_name)) }
      end
    end
  end
end
