# frozen_string_literal: true

require "rails_helper"

RSpec.describe AppleVerification::GuestManifest::Build do
  # @spec APPLE-WORKER-013
  it "derives build and test operations without capture operations" do
    attempt = attempt_for(<<~YAML)
      version: 1
      profiles:
        mac-app:
          platform: macos
          xcode:
            workspace: Mac.xcworkspace
            scheme: Mac
          bootstrap: spm
          tests:
            required: true
    YAML

    expect(operation_types(attempt)).to eq(%w[materialize_source resolve_swift_packages build test export_artifacts])
  end

  # @spec APPLE-WORKER-013
  it "sets up an iOS simulator with the configured bundle before its capture flow" do
    attempt = attempt_for(mixed_profiles_yaml)

    operations = described_class.call(attempt:)

    expect(operations.map { |operation| operation.fetch("type") }).to eq(
      %w[materialize_source build boot_simulator install_app launch_app capture build launch_app capture export_artifacts]
    )
    expect(operations[2].fetch("payload")).to eq("destination" => "iPhone 17")
    expect(operations[3].fetch("payload")).to eq("bundle_id" => "dev.paid.ios")
    expect(operations[4].fetch("payload")).to eq("bundle_id" => "dev.paid.ios")
    expect(operations[5].dig("payload", "target")).to eq("simulator_screen")
    expect(operations[7].fetch("payload")).to eq("bundle_id" => "dev.paid.mac")
    expect(operations[8].dig("payload", "target")).to eq("app_window")
  end

  def attempt_for(content)
    attempt = create(:apple_verification_attempt)
    revision = attempt.apple_verification_workflow_revision
    revision.update_columns(configuration_content: content, content_digest: "sha256:#{Digest::SHA256.hexdigest(content)}")
    attempt
  end

  def operation_types(attempt)
    described_class.call(attempt:).map { |operation| operation.fetch("type") }
  end

  def mixed_profiles_yaml
    <<~YAML
      version: 1
      profiles:
        ios-app:
          platform: ios
          worker:
            simulator: iPhone 17
          xcode:
            project: iOS.xcodeproj
            scheme: IOS
            bundle_id: dev.paid.ios
          captures:
            - id: ios-screen
              required: true
              flow: [ { launch_app: {} }, { capture: {} } ]
        mac-app:
          platform: macos
          xcode:
            project: Mac.xcodeproj
            scheme: Mac
            bundle_id: dev.paid.mac
          captures:
            - id: mac-screen
              required: true
              flow: [ { launch_app: {} }, { capture: {} } ]
    YAML
  end
end
