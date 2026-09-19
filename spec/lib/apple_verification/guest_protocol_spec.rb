# frozen_string_literal: true

require "rails_helper"

RSpec.describe AppleVerification::GuestProtocol do # @spec APPLE-VERIFY-003, APPLE-VERIFY-004
  describe ".validate!" do
    it "accepts versioned typed verification operations" do
      manifest = {
        "version" => 1,
        "operations" => [
          { "type" => "materialize_source", "payload" => { "digest" => "sha256:source" } },
          { "type" => "resolve_swift_packages", "payload" => {} },
          { "type" => "inspect_xcode", "payload" => { "scheme" => "App" } },
          { "type" => "build", "payload" => { "scheme" => "App" } },
          { "type" => "test", "payload" => { "scheme" => "App" } },
          { "type" => "boot_simulator", "payload" => { "destination" => "iPhone 17" } },
          { "type" => "launch_app", "payload" => { "bundle_id" => "test.App" } },
          { "type" => "ui_action", "payload" => { "action" => "tap", "accessibility_id" => "continue" } },
          { "type" => "capture", "payload" => { "platform" => "ios", "target" => "simulator_screen", "name" => "initial" } },
          { "type" => "collect_diagnostics", "payload" => {} },
          { "type" => "export_artifacts", "payload" => {} }
        ]
      }

      expect(described_class.validate!(manifest)).to eq(manifest)
    end

    it "rejects unsupported protocol versions, operations, malformed payloads, and shell text" do
      expect { described_class.validate!("version" => 2, "operations" => []) }.to raise_error(described_class::UnsupportedVersionError)
      expect { described_class.validate!("version" => 1, "operations" => [ { "type" => "shell", "payload" => {} } ]) }.to raise_error(described_class::UnsupportedOperationError)
      expect { described_class.validate!("version" => 1, "operations" => [ { "type" => "build", "payload" => "App" } ]) }.to raise_error(described_class::InvalidManifestError)
      expect { described_class.validate!("version" => 1, "operations" => [ { "type" => "build", "payload" => { "command" => "rm -rf /" } } ]) }.to raise_error(described_class::ArbitraryShellError)
    end
  end

  describe ".capture_failure" do
    it "returns a precise failure with platform and capture target" do
      result = described_class.capture_failure(platform: "macos", target: "app_window", stage: "selection", message: "window not found")

      expect(result).to eq(
        "status" => "failed",
        "failure_class" => "capture_selection",
        "platform" => "macos",
        "target" => "app_window",
        "message" => "window not found"
      )
    end
  end

  describe AppleVerification::GuestExecutor do
    it "dispatches only operations admitted by the protocol" do
      executor = described_class.new(build: ->(payload) { { "scheme" => payload.fetch("scheme") } })

      result = executor.execute!("version" => 1, "operations" => [ { "type" => "build", "payload" => { "scheme" => "App" } } ])

      expect(result).to eq([ { "scheme" => "App" } ])
    end
  end
end
