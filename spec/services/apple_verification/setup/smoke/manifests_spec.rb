# frozen_string_literal: true

require "rails_helper"

# @spec APPLE-SETUP-004
RSpec.describe AppleVerification::Setup::Smoke::Manifests do
  let(:source_digest) { "0" * 64 }

  describe ".smoke_ios_app" do
    it "builds a closed-protocol manifest for the smoke iOS app" do
      manifest = described_class.smoke_ios_app(source_digest:)

      expect(manifest["version"]).to eq(AppleVerification::GuestProtocol::VERSION)
      operations = manifest["operations"].map { |op| op["type"] }
      expect(operations).to include("materialize_source", "build", "test", "boot_simulator",
        "install_app", "launch_app", "ui_action", "capture", "export_artifacts")
      expect { AppleVerification::GuestProtocol.validate!(manifest) }.not_to raise_error
    end
  end

  describe ".colormatching_ios" do
    it "builds a closed-protocol manifest for the viamin/ColorMatching-iOS scheme" do
      manifest = described_class.colormatching_ios(source_digest:)
      operations = manifest["operations"].map { |op| op["type"] }
      expect(operations).to include("materialize_source", "resolve_swift_packages", "build", "test",
        "boot_simulator", "install_app", "launch_app", "capture", "export_artifacts")
      expect { AppleVerification::GuestProtocol.validate!(manifest) }.not_to raise_error
    end

    it "places the test operation immediately after build so synthesize_outcomes can surface test_outcome" do
      manifest = described_class.colormatching_ios(source_digest:)
      operations = manifest["operations"].map { |op| op["type"] }
      build_index = operations.index("build")
      expect(operations[build_index + 1]).to eq("test")
    end
  end

  describe ".macos_gui_app" do
    it "builds a closed-protocol manifest that captures the macOS app window" do
      manifest = described_class.macos_gui_app(source_digest:)
      capture = manifest["operations"].find { |op| op["type"] == "capture" }
      expect(capture["payload"]["platform"]).to eq("macos")
      expect(capture["payload"]["target"]).to eq("app_window")
      expect { AppleVerification::GuestProtocol.validate!(manifest) }.not_to raise_error
    end

    it "does not include any shell-shaped fields in any operation" do
      manifest = described_class.macos_gui_app(source_digest:)
      manifest["operations"].each do |operation|
        payload = operation.fetch("payload")
        expect(payload).not_to have_key("command")
        expect(payload).not_to have_key("shell")
        expect(payload).not_to have_key("executable")
        expect(payload).not_to have_key("script")
      end
    end

    it "includes the test operation between build and launch_app" do
      manifest = described_class.macos_gui_app(source_digest:)
      operations = manifest["operations"].map { |op| op["type"] }
      expect(operations).to include("test")
      build_index = operations.index("build")
      expect(operations[build_index + 1]).to eq("test")
    end
  end

  describe ".synthesize_outcomes" do
    it "returns an empty hash when no operations are returned" do
      expect(described_class.synthesize_outcomes([], "build-test-colormatching-ios")).to eq({})
      expect(described_class.synthesize_outcomes(nil, "build-test-colormatching-ios")).to eq({})
    end

    it "surfaces build and test outcomes from the operations list" do
      operations = [
        { "type" => "build", "outcome" => "succeeded" },
        { "type" => "test", "outcome" => "succeeded" }
      ]
      result = described_class.synthesize_outcomes(operations, "build-test-colormatching-ios")
      expect(result).to include(
        "build_outcome" => "succeeded",
        "test_outcome" => "succeeded",
        "launch_outcome" => "missing"
      )
    end

    it "falls back to status when the operation has no outcome key" do
      operations = [
        { "type" => "launch_app", "status" => "succeeded" }
      ]
      result = described_class.synthesize_outcomes(operations, "smoke-ios-app-launch")
      expect(result["launch_outcome"]).to eq("succeeded")
    end

    it "pulls the PNG byte count from the capture operation's payload" do
      operations = [
        { "type" => "capture", "payload" => { "bytes" => 4242 } }
      ]
      result = described_class.synthesize_outcomes(operations, "macos-app-screenshot")
      expect(result.dig("artifacts", "app_window_png_bytes")).to eq(4242)
    end

    it "records missing when the expected operation did not run" do
      result = described_class.synthesize_outcomes(
        [ { "type" => "build", "status" => "succeeded" } ],
        "build-test-colormatching-ios"
      )
      expect(result["test_outcome"]).to eq("missing")
    end
  end
end
