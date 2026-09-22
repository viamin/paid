# frozen_string_literal: true

require "rails_helper"

# @spec APPLE-LIVE-002
RSpec.describe AppleVerification::LiveValidation::FunctionalManifests do
  it "builds a protocol-valid manifest for every functional scenario" do
    %w[functional-smoke-ios-app functional-colormatching-ios functional-macos-gui-app].each do |scenario_id|
      manifest = described_class.for(scenario_id, source_digest: "a" * 64)

      expect { AppleVerification::GuestProtocol.validate!(manifest) }.not_to raise_error
    end
  end

  it "walks the full build, test, launch, and capture sequence for iOS targets" do
    manifest = described_class.for("functional-smoke-ios-app", source_digest: "a" * 64)

    expect(manifest.fetch("version")).to eq(1)
    types = manifest.fetch("operations").map { |operation| operation.fetch("type") }
    expect(types).to eq(%w[
      materialize_source resolve_swift_packages inspect_xcode build test
      boot_simulator install_app launch_app ui_action capture export_artifacts
    ])
  end

  it "captures the simulator screen for iOS and the app window for macOS" do
    ios = described_class.for("functional-smoke-ios-app", source_digest: "a" * 64)
    mac = described_class.for("functional-macos-gui-app", source_digest: "a" * 64)

    ios_capture = ios.fetch("operations").find { |operation| operation.fetch("type") == "capture" }.fetch("payload")
    expect(ios_capture).to include("platform" => "ios", "target" => "simulator_screen")

    mac_types = mac.fetch("operations").map { |operation| operation.fetch("type") }
    expect(mac_types).not_to include("boot_simulator", "install_app")
    mac_capture = mac.fetch("operations").find { |operation| operation.fetch("type") == "capture" }.fetch("payload")
    expect(mac_capture).to include("platform" => "macos", "target" => "app_window")
  end

  it "materializes the exact source digest and carries no shell text" do
    manifest = described_class.for("functional-colormatching-ios", source_digest: "b" * 64)

    materialize = manifest.fetch("operations").find { |operation| operation.fetch("type") == "materialize_source" }
    expect(materialize.fetch("payload")).to eq("digest" => "b" * 64)
    expect(manifest.to_s).not_to match(/\b(command|shell|script|executable)\b/)
  end

  it "raises for an unknown functional scenario" do
    expect { described_class.for("functional-nope", source_digest: "a" * 64) }
      .to raise_error(ArgumentError, /unknown functional scenario/)
  end
end
