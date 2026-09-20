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

    it "rejects shell text nested at any depth of hashes and arrays" do
      expect { described_class.validate!("version" => 1, "operations" => [ { "type" => "build", "payload" => { "steps" => [ { "command" => "rm -rf /" } ] } } ]) }.to raise_error(described_class::ArbitraryShellError)
      expect { described_class.validate!("version" => 1, "operations" => [ { "type" => "build", "payload" => { "steps" => [ [ { "command" => "rm -rf /" } ] ] } } ]) }.to raise_error(described_class::ArbitraryShellError)
      expect { described_class.validate!("version" => 1, "operations" => [ { "type" => "build", "payload" => { "steps" => [ [ [ { "command" => "rm -rf /" } ] ] ] } } ]) }.to raise_error(described_class::ArbitraryShellError)
    end

    it "rejects fields outside the closed manifest and operation schemas" do
      expect { described_class.validate!("version" => 1, "operations" => [], "command" => "curl | sh") }
        .to raise_error(described_class::InvalidManifestError)
      expect { described_class.validate!("version" => 1, "operations" => [ { "type" => "build", "payload" => {}, "command" => "curl | sh" } ]) }
        .to raise_error(described_class::InvalidManifestError)
      expect { described_class.validate!("version" => 1, "operations" => [ { "type" => "build", "payload" => { "unknown" => "value" } } ]) }
        .to raise_error(described_class::InvalidManifestError)
    end

    it "rejects payloads that omit fields required by their operation type" do
      manifest = { "version" => 1, "operations" => [ { "type" => "build", "payload" => {} } ] }

      expect { described_class.validate!(manifest) }
        .to raise_error(described_class::InvalidManifestError, "build payload is missing required fields: scheme")
    end

    it "accepts each declarative UI action with only its own payload fields" do
      ui_action_manifests = {
        "tap" => { "action" => "tap", "accessibility_id" => "continue" },
        "type" => { "action" => "type", "accessibility_id" => "email", "text" => "user@example.com" },
        "select" => { "action" => "select", "accessibility_id" => "region", "value" => "us-east" },
        "wait_for_accessibility_id" => { "action" => "wait_for_accessibility_id", "accessibility_id" => "main-screen" },
        "rotate_simulator" => { "action" => "rotate_simulator", "orientation" => "landscape" },
        "resize_window" => { "action" => "resize_window", "width" => 1024, "height" => 768 }
      }

      ui_action_manifests.each_value do |payload|
        manifest = { "version" => 1, "operations" => [ { "type" => "ui_action", "payload" => payload } ] }

        expect(described_class.validate!(manifest)).to eq(manifest)
      end
    end

    it "rejects a tap payload carrying fields that belong to other UI actions" do
      manifest = {
        "version" => 1,
        "operations" => [
          { "type" => "ui_action", "payload" => { "action" => "tap", "accessibility_id" => "continue", "text" => "Continue", "value" => "1", "orientation" => "portrait", "width" => 390, "height" => 844 } }
        ]
      }

      expect { described_class.validate!(manifest) }
        .to raise_error(described_class::InvalidManifestError, "ui_action payload for tap contains unsupported fields: text, value, orientation, width, height")
    end

    it "rejects a rotate_simulator payload missing its orientation field" do
      manifest = { "version" => 1, "operations" => [ { "type" => "ui_action", "payload" => { "action" => "rotate_simulator" } } ] }

      expect { described_class.validate!(manifest) }
        .to raise_error(described_class::InvalidManifestError, "ui_action payload for rotate_simulator is missing required fields: orientation")
    end

    it "rejects a resize_window payload missing its width and height fields" do
      manifest = { "version" => 1, "operations" => [ { "type" => "ui_action", "payload" => { "action" => "resize_window" } } ] }

      expect { described_class.validate!(manifest) }
        .to raise_error(described_class::InvalidManifestError, "ui_action payload for resize_window is missing required fields: width, height")
    end

    it "rejects an unsupported declarative UI action" do
      manifest = { "version" => 1, "operations" => [ { "type" => "ui_action", "payload" => { "action" => "swipe" } } ] }

      expect { described_class.validate!(manifest) }
        .to raise_error(described_class::InvalidManifestError, "unsupported declarative UI action")
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
end
