# frozen_string_literal: true

require "rails_helper"

RSpec.describe AppleVerificationAttempts::GuestResult do
  # @spec APPLE-ATTEMPT-009
  it "fails closed when the approved revision requires an operation absent from the manifest" do
    revision = build_stubbed(:apple_verification_workflow_revision, required_checks: [ "ios-app.tests" ])
    manifest = { "operations" => [ { "type" => "materialize_source", "payload" => {} } ] }

    result = described_class.call(revision:, manifest:, operations: [ { "type" => "materialize_source", "status" => "succeeded" } ])

    expect(result).to have_attributes(status: "failed", failure_classification: "project_configuration")
  end

  # @spec APPLE-ATTEMPT-009
  it "does not let an advisory operation satisfy a required check" do
    revision = build_stubbed(:apple_verification_workflow_revision, required_checks: [ "ios-app.tests" ])
    manifest = { "operations" => [ { "type" => "test", "payload" => { "scheme" => "App" }, "required" => false } ] }

    result = described_class.call(revision:, manifest:, operations: [ { "type" => "test", "status" => "succeeded" } ])

    expect(result).to have_attributes(status: "failed", failure_classification: "project_configuration")
  end

  # @spec APPLE-ATTEMPT-009
  it "classifies a failed test operation" do
    revision = build_stubbed(:apple_verification_workflow_revision, required_checks: [ "ios-app.tests" ])
    manifest = { "operations" => [ { "type" => "test", "payload" => { "scheme" => "App" } } ] }

    result = described_class.call(revision:, manifest:, operations: [ { "type" => "test", "status" => "failed" } ])

    expect(result).to have_attributes(status: "failed", failure_classification: "test_assertion")
  end

  # @spec APPLE-ATTEMPT-012
  it "succeeds when advisory test and capture operations fail after required work succeeds" do
    revision = build_stubbed(:apple_verification_workflow_revision, required_checks: [ "ios-app.tests" ])
    manifest = {
      "operations" => [
        { "type" => "build", "payload" => { "scheme" => "App" }, "required" => true },
        { "type" => "test", "payload" => { "scheme" => "App" }, "required" => true },
        { "type" => "test", "payload" => { "scheme" => "Advisory" }, "required" => false },
        { "type" => "capture", "payload" => { "platform" => "ios", "target" => "simulator_screen", "name" => "advisory" }, "required" => false }
      ]
    }
    operations = [
      { "type" => "build", "status" => "succeeded" },
      { "type" => "test", "status" => "succeeded" },
      { "type" => "test", "status" => "failed" },
      { "type" => "capture", "status" => "failed" }
    ]

    result = described_class.call(revision:, manifest:, operations:)

    expect(result).to have_attributes(status: "succeeded", failure_classification: nil)
  end

  # @spec APPLE-ATTEMPT-009
  it "accepts required build, test, and capture work once the derived operations report success" do
    revision = build_stubbed(:apple_verification_workflow_revision, required_checks: [ "ios-app.tests", "ios-app.initial-screen" ])
    manifest = {
      "operations" => [
        { "type" => "build", "payload" => { "scheme" => "App" } },
        { "type" => "test", "payload" => { "scheme" => "App" } },
        { "type" => "capture", "payload" => { "platform" => "ios", "target" => "simulator_screen", "name" => "initial-screen" } }
      ]
    }

    result = described_class.call(revision:, manifest:, operations: manifest.fetch("operations").map { |operation| { "type" => operation.fetch("type"), "status" => "succeeded" } })

    expect(result).to have_attributes(status: "succeeded", failure_classification: nil)
  end

  # @spec APPLE-ATTEMPT-009
  it "fails when the guest omits a dispatched operation result" do
    revision = build_stubbed(:apple_verification_workflow_revision, required_checks: [])
    manifest = { "operations" => [ { "type" => "materialize_source", "payload" => {} } ] }

    result = described_class.call(revision:, manifest:, operations: [])

    expect(result).to have_attributes(status: "failed", failure_classification: "worker_infrastructure")
  end

  # @spec APPLE-ATTEMPT-009
  it "classifies a malformed guest operation as worker infrastructure" do
    revision = build_stubbed(:apple_verification_workflow_revision, required_checks: [])
    manifest = { "operations" => [ { "type" => "materialize_source", "payload" => {} } ] }

    result = described_class.call(revision:, manifest:, operations: [ [] ])

    expect(result).to have_attributes(status: "failed", failure_classification: "worker_infrastructure")
  end
end
