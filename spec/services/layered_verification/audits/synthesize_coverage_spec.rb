# frozen_string_literal: true

require "rails_helper"

RSpec.describe LayeredVerification::Audits::SynthesizeCoverage do
  # @spec LAYERED-VERIFY-017 @spec LAYERED-VERIFY-024
  it "attaches repeated observations to the same unresolved scoped cause" do
    obligation = create(:layered_verification_obligation)
    run = create(:agent_run, project: obligation.project, goal: "layered_verification_audit")
    attributes = { obligation:, agent_run: run, cause_signature: "missing-payment-transition", source_passages: [ "intent" ], observed_behavior: { "code" => "omits transition" }, check_limitations: [ "static review" ] }

    first = described_class.call(**attributes)
    second = described_class.call(**attributes)

    expect(second).to eq(first)
    expect(first.observation_history.size).to eq(2)
  end
end
