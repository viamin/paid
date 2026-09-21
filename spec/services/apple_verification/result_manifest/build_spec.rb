# frozen_string_literal: true

require "rails_helper"

# @spec APPLE-TRANSFER-004
RSpec.describe AppleVerification::ResultManifest::Build do
  let(:account) { create(:account) }
  let(:project) { create(:project, account: account) }
  let(:workflow_revision) { create(:apple_verification_workflow_revision, project: project, account: account) }
  let(:attempt) do
    create(:apple_verification_attempt, :succeeded,
      apple_verification_workflow_revision: workflow_revision,
      project: project,
      account: account)
  end

  let(:artifact_references) do
    [ { "lane" => "object_storage", "kind" => "xcresult", "locator" => { "key" => "apple-verification/x/y/z/xcresult/App.xcresult" } } ]
  end

  it "builds a structured output manifest with attempt and result sections" do
    result = described_class.call(
      attempt: attempt,
      artifact_references: artifact_references,
      audit_event_references: [ 1, 2 ],
      ledger_entry_references: [ 10 ],
      required_checks: [ "test" ],
      advisory_checks: [ "screenshot" ],
      screenshot_metadata: [ "initial-screen" ],
      timings: { "queued_ms" => 100, "provisioning_ms" => 500, "running_ms" => 5000, "total_ms" => 5600 }
    )

    manifest = result.manifest.as_json
    expect(manifest.dig("attempt", "source_digest")).to eq(attempt.source_digest)
    expect(manifest.dig("attempt", "workflow_revision")).to eq(workflow_revision.id)
    expect(manifest.dig("attempt", "lifecycle_gate")).to eq(attempt.lifecycle_gate)
    expect(manifest.dig("attempt", "profile_digest")).to eq(workflow_revision.apple_worker_profile.image_digest)
  end

  it "populates the result section with status, timings, lineage, checks, and references" do
    result = described_class.call(
      attempt: attempt,
      artifact_references: artifact_references,
      audit_event_references: [ 1, 2 ],
      ledger_entry_references: [ 10 ],
      required_checks: [ "test" ],
      advisory_checks: [ "screenshot" ],
      screenshot_metadata: [ "initial-screen" ],
      timings: { "queued_ms" => 100, "provisioning_ms" => 500, "running_ms" => 5000, "total_ms" => 5600 }
    )

    manifest = result.manifest.as_json
    expect(manifest.dig("result", "status")).to eq("succeeded")
    expect(manifest.dig("result", "timings", "total_ms")).to eq(5600)
    expect(manifest.dig("result", "retry_lineage")).to include(attempt.id.to_s)
    expect(manifest.dig("result", "required_checks")).to eq([ "test" ])
    expect(manifest.dig("result", "advisory_checks")).to eq([ "screenshot" ])
    expect(manifest.dig("result", "screenshot_metadata")).to eq([ "initial-screen" ])
    expect(manifest.dig("result", "audit_event_references")).to eq([ "1", "2" ])
    expect(manifest.dig("result", "ledger_entry_references")).to eq([ "10" ])
    expect(manifest.dig("artifacts", "xcresult").length).to eq(1)
  end

  it "omits retry lineage entries from other projects or unrelated attempts" do
    other_project = create(:project, account: account)
    other_workflow = create(:apple_verification_workflow_revision, project: other_project, account: account)
    create(:apple_verification_attempt, apple_verification_workflow_revision: other_workflow,
      project: other_project, account: account, source_digest: "sha256:#{'e' * 64}")

    result = described_class.call(attempt: attempt)

    expect(result.manifest.as_json.dig("result", "retry_lineage")).to eq([ attempt.id.to_s ])
  end
end
