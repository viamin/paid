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

    operations = described_class.call(attempt:)

    expect(operations.map { |operation| operation.fetch("type") }).to eq(%w[materialize_source resolve_swift_packages build test export_artifacts])
    expect(operations[2].fetch("payload")).to eq("workspace" => "Mac.xcworkspace", "scheme" => "Mac")
    expect(operations[3].fetch("payload")).to eq("workspace" => "Mac.xcworkspace", "scheme" => "Mac")
  end

  # @spec APPLE-WORKER-013
  it "dispatches the approved Xcode project and test plan with build and test operations" do
    attempt = attempt_for(project_with_test_plan_yaml)

    operations = described_class.call(attempt:)

    expected_build_payload = {
      "project" => "Apps/Example.xcodeproj",
      "scheme" => "Example"
    }
    expected_test_payload = expected_build_payload.merge(
      "test_plan" => "Plans/Regression.xctestplan"
    )
    expect(operations[1].fetch("payload")).to eq(expected_build_payload)
    expect(operations[2].fetch("payload")).to eq(expected_test_payload)
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

  # @spec APPLE-WORKER-013
  it "marks advisory tests and capture flows without suppressing their dispatch" do
    attempt = attempt_for(<<~YAML)
      version: 1
      profiles:
        app:
          platform: ios
          worker:
            simulator: iPhone 17
          xcode:
            project: App.xcodeproj
            scheme: App
            bundle_id: dev.paid.app
          tests:
            required: false
          captures:
            - id: advisory-screen
              required: false
              flow: [ { launch_app: {} }, { capture: {} } ]
    YAML

    operations = described_class.call(attempt:)

    expect(operations.filter { |operation| %w[test boot_simulator install_app launch_app capture].include?(operation.fetch("type")) }).to all(include("required" => false))
  end

  # @spec APPLE-RESULT-006
  # @spec APPLE-WORKER-013
  it "dispatches only a requested capture with its profile setup" do
    attempt = attempt_for(mixed_profiles_with_multiple_captures_yaml, requested_capture: "ios-app.second-screen")

    operations = described_class.call(attempt:)

    expect(operations.map { |operation| operation.fetch("type") }).to eq(
      %w[materialize_source build boot_simulator install_app launch_app capture export_artifacts]
    )
    expect(operations.last(3).map { |operation| operation.dig("payload", "name") }).to eq([ nil, "second-screen", nil ])
    expect(operations.filter { |operation| %w[boot_simulator install_app launch_app capture].include?(operation.fetch("type")) }).to all(include("required" => false))
  end

  def attempt_for(content, requested_capture: nil)
    attempt = create(:apple_verification_attempt, requested_capture:)
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

  def mixed_profiles_with_multiple_captures_yaml
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
            - id: first-screen
              required: true
              flow: [ { launch_app: {} }, { capture: {} } ]
            - id: second-screen
              required: false
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

  def project_with_test_plan_yaml
    <<~YAML
      version: 1
      profiles:
        app:
          platform: ios
          xcode:
            project: Apps/Example.xcodeproj
            scheme: Example
            test_plan: Plans/Regression.xctestplan
          tests:
            required: true
    YAML
  end
end
