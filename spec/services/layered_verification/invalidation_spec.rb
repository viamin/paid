# frozen_string_literal: true

require "rails_helper"

RSpec.describe LayeredVerification::Invalidation do
  # @spec LAYERED-VERIFY-019
  it "reuses evidence with a complete matching dependency basis and invalidates changed or unknown dependencies" do
    project = create(:project)
    obligation = create(:layered_verification_obligation, project:, external_revision: "intent-v2")
    matching = create(:layered_verification_check_result, obligation:, input_revision: {
      "code" => "code-v2", "external_revision" => "intent-v2",
      "dependencies" => { "environment" => "ruby-3.4", "tool" => "tlc-2.18" }
    })
    changed = create(:layered_verification_check_result, obligation:, input_revision: {
      "code" => "code-v1", "external_revision" => "intent-v2",
      "dependencies" => { "environment" => "ruby-3.4", "tool" => "tlc-2.18" }
    })
    incomplete = create(:layered_verification_check_result, obligation:, input_revision: { "code" => "code-v2" })

    impact = described_class.call(obligations: [ obligation ], target_revision: "code-v2",
      dependencies: { "environment" => "ruby-3.4", "tool" => "tlc-2.18" })

    expect(impact.reusable_result_ids).to eq([ matching.id ])
    expect(impact.invalidated_result_ids).to contain_exactly(changed.id, incomplete.id)
    expect(impact.limitations).to include(a_string_matching(/complete dependency basis/))
    expect(changed.reload.execution_state).to eq("completed")
  end
end
