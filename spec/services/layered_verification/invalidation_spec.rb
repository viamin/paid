# frozen_string_literal: true

require "rails_helper"

RSpec.describe LayeredVerification::Invalidation do
  let(:dependencies) do
    { "environment" => { "immutable" => true, "digest" => "sha256:runtime" },
      "producer_versions" => { "paid" => "1.2.3" },
      "tool_versions" => { "tlc_runtime_image_digest" => "sha256:runtime" } }
  end

  # @spec LAYERED-VERIFY-019
  it "reuses evidence with a complete matching dependency basis and invalidates changed or unknown dependencies" do
    project = create(:project)
    obligation = create(:layered_verification_obligation, project:, external_revision: "intent-v2")
    matching = create(:layered_verification_check_result, obligation:, input_revision: {
      "code" => "code-v2", "external_revision" => "intent-v2",
      "dependencies" => dependencies
    })
    changed = create(:layered_verification_check_result, obligation:, input_revision: {
      "code" => "code-v1", "external_revision" => "intent-v2",
      "dependencies" => dependencies
    })
    incomplete = create(:layered_verification_check_result, obligation:, input_revision: { "code" => "code-v2" })

    impact = described_class.call(obligations: [ obligation ], target_revision: "code-v2", dependencies:)

    expect(impact.reusable_result_ids).to eq([ matching.id ])
    expect(impact.invalidated_result_ids).to contain_exactly(changed.id, incomplete.id)
    expect(impact.limitations).to include(a_string_matching(/complete dependency basis/))
    expect(changed.reload.execution_state).to eq("completed")
  end

  # @spec LAYERED-VERIFY-019
  it "invalidates matching hashes when concrete runtime or producer versions are absent" do
    project = create(:project)
    obligation = create(:layered_verification_obligation, project:, external_revision: "intent-v2")
    result = create(:layered_verification_check_result, obligation:, input_revision: {
      "code" => "code-v2", "external_revision" => "intent-v2",
      "dependencies" => { "environment" => "isolated_execution_environment", "producer_versions" => { "paid" => "unversioned" } }
    })

    impact = described_class.call(obligations: [ obligation ], target_revision: "code-v2",
      dependencies: result.input_revision.fetch("dependencies"))

    expect(impact.invalidated_result_ids).to eq([ result.id ])
    expect(impact.reusable_result_ids).to be_empty
  end
end
