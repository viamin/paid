# frozen_string_literal: true

module AppleVerification
  module Setup
    module Smoke
      # Builds the closed-protocol guest manifests the smoke tests dispatch.
      # The defaults mirror the live-validation functional manifests but are
      # scoped to the smallest manifest each criterion can prove.
      # @spec APPLE-SETUP-004
      module Manifests
        IOS_TARGETS = {
          smoke_ios_app: {
            scheme: "SmokeApp", destination: "iPhone 17", bundle_id: "dev.paid.smokeapp",
            accessibility_id: "main-screen", capture_name: "initial-screen"
          },
          colormatching_ios: {
            scheme: "ColorMatchingLPS", destination: "iPhone 17", bundle_id: "dev.viamin.colormatchinglps",
            accessibility_id: "main-screen", capture_name: "initial-screen"
          }
        }.freeze

        MACOS_TARGET = {
          macos_gui_app: {
            scheme: "ExampleMac", bundle_id: "dev.paid.examplemac",
            accessibility_id: "main-window", capture_name: "main-window"
          }
        }.freeze

        IOS_CAPTURE = { "platform" => "ios", "target" => "simulator_screen" }.freeze
        MACOS_CAPTURE = { "platform" => "macos", "target" => "app_window" }.freeze

        module_function

        def smoke_ios_app(source_digest:)
          ios_manifest(IOS_TARGETS.fetch(:smoke_ios_app), source_digest)
        end

        def colormatching_ios(source_digest:)
          ios_manifest(IOS_TARGETS.fetch(:colormatching_ios), source_digest)
        end

        def macos_gui_app(source_digest:)
          macos_manifest(MACOS_TARGET.fetch(:macos_gui_app), source_digest)
        end

        def ios_manifest(target, source_digest)
          operations = [
              { "type" => "materialize_source", "payload" => { "digest" => source_digest } },
              { "type" => "resolve_swift_packages", "payload" => {} },
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
            .then { |manifest| AppleVerification::GuestProtocol.validate!(manifest) }
        end

        def macos_manifest(target, source_digest)
          operations = [
              { "type" => "materialize_source", "payload" => { "digest" => source_digest } },
              { "type" => "resolve_swift_packages", "payload" => {} },
              { "type" => "build", "payload" => { "scheme" => target.fetch(:scheme) } },
              { "type" => "test", "payload" => { "scheme" => target.fetch(:scheme) } },
              { "type" => "launch_app", "payload" => { "bundle_id" => target.fetch(:bundle_id) } },
              readiness_action(target),
              capture_operation(MACOS_CAPTURE, target),
              { "type" => "export_artifacts", "payload" => {} }
            ]
          { "version" => AppleVerification::GuestProtocol::VERSION, "operations" => operations }
            .then { |manifest| AppleVerification::GuestProtocol.validate!(manifest) }
        end

        def readiness_action(target)
          { "type" => "ui_action",
            "payload" => { "action" => "wait_for_accessibility_id",
                            "accessibility_id" => target.fetch(:accessibility_id) } }
        end

        def capture_operation(capture, target)
          { "type" => "capture", "payload" => capture.merge("name" => target.fetch(:capture_name)) }
        end

        # Reduces the executor's operations list into the top-level outcome
        # hash the {AppleVerification::Setup::SmokeTests} scenarios assert
        # against. The closed GuestProtocol vocabulary returns each operation
        # as { "type" => "...", "status" => "...", optional "payload" /
        # "outcome" }, so we surface the relevant per-scenario outcome at the
        # top level (build/test/launch_app) and pull the captured PNG byte
        # count into +artifacts.app_window_png_bytes+ when the run included a
        # +capture+ operation. Outcomes without a +status+ or +outcome+ field
        # are recorded as +missing+ rather than silently reporting success.
        def synthesize_outcomes(operations, _scenario_id)
          return {} unless operations.is_a?(Array) && operations.any?

          {
            "build_outcome" => outcome_for(operations, "build"),
            "test_outcome" => outcome_for(operations, "test"),
            "launch_outcome" => outcome_for(operations, "launch_app"),
            "artifacts" => { "app_window_png_bytes" => capture_bytes(operations) }
          }
        end

        def outcome_for(operations, type)
          op = operations.find { |entry| entry.is_a?(Hash) && entry["type"] == type }
          return "missing" if op.nil?

          op["outcome"].presence || op["status"].to_s.presence || "missing"
        end

        def capture_bytes(operations)
          capture = operations.find { |entry| entry.is_a?(Hash) && entry["type"] == "capture" }
          return 0 if capture.nil?

          capture.dig("payload", "bytes").to_i
        end
      end
    end
  end
end
