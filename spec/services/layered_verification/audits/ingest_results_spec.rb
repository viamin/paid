# frozen_string_literal: true

require "rails_helper"

RSpec.describe LayeredVerification::Audits::IngestResults do
  # @spec LAYERED-VERIFY-008 LAYERED-VERIFY-022 LAYERED-VERIFY-024
  it "does not replace a recorder-owned formal result with an agent report" do
    audit = create(:agent_run, goal: "layered_verification_audit")
    obligation = create(:layered_verification_obligation, project: audit.project)
    audit.update!(external_metadata: { "layered_verification" => {
      "obligation_ids" => [ obligation.id ], "target_revision" => "abc123",
      "plan" => { obligation.id.to_s => { "selected_checks" => [ "formal_verification" ] } }
    } })
    recorded = create(:layered_verification_check_result, obligation:, agent_run: audit,
      agent_reported: { "selected_check" => "formal_verification" })
    audit.log!("stdout", "paid-layered-verification-output\n" \
      "{\"check_results\":[{\"obligation_id\":#{obligation.id},\"selected_check\":\"formal_verification\"}]}\n" \
      "paid-layered-verification-output\n")

    described_class.call(agent_run: audit)

    expect(obligation.check_results).to contain_exactly(recorded)
  end
end
