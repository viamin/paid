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
      expect(operations).to include("materialize_source", "build", "boot_simulator", "install_app",
        "launch_app", "ui_action", "capture", "export_artifacts")
      expect { AppleVerification::GuestProtocol.validate!(manifest) }.not_to raise_error
    end
  end

  describe ".colormatching_ios" do
    it "builds a closed-protocol manifest for the viamin/ColorMatching-iOS scheme" do
      manifest = described_class.colormatching_ios(source_digest:)
      operations = manifest["operations"].map { |op| op["type"] }
      expect(operations).to include("materialize_source", "resolve_swift_packages", "build",
        "boot_simulator", "install_app", "launch_app", "capture", "export_artifacts")
      expect { AppleVerification::GuestProtocol.validate!(manifest) }.not_to raise_error
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
  end
end
