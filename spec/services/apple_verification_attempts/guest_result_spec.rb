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
  it "classifies a failed test operation" do
    revision = build_stubbed(:apple_verification_workflow_revision, required_checks: [ "ios-app.tests" ])
    manifest = { "operations" => [ { "type" => "test", "payload" => { "scheme" => "App" } } ] }

    result = described_class.call(revision:, manifest:, operations: [ { "type" => "test", "status" => "failed" } ])

    expect(result).to have_attributes(status: "failed", failure_classification: "test_assertion")
  end

  # @spec APPLE-ATTEMPT-009
  it "fails when the guest omits a dispatched operation result" do
    revision = build_stubbed(:apple_verification_workflow_revision, required_checks: [])
    manifest = { "operations" => [ { "type" => "materialize_source", "payload" => {} } ] }

    result = described_class.call(revision:, manifest:, operations: [])

    expect(result).to have_attributes(status: "failed", failure_classification: "worker_infrastructure")
  end
end
