# frozen_string_literal: true

require "rails_helper"

RSpec.describe LayeredVerificationCheckResult do
  # @spec LAYERED-VERIFY-008
  it "records execution state independently from coverage and preserves each execution" do
    obligation = create(:layered_verification_obligation)
    attributes = {
      obligation:,
      producer: "formal_verification",
      execution_state: "completed",
      obligation_coverage: "contradicted",
      input_revision: { "intent" => "abc123" },
      limitations: "bounded state space"
    }

    expect { 2.times { described_class.create!(attributes) } }.to change(described_class, :count).by(2)
  end

  # @spec LAYERED-VERIFY-008
  it "does not permit a recorded result to be overwritten" do
    result = create(:layered_verification_check_result)

    expect { result.update!(limitations: "changed") }
      .to raise_error(described_class::ImmutableResultError)
  end

  # @spec LAYERED-VERIFY-008
  it "keeps claim and run evidence inside the recorded obligation" do
    obligation = create(:layered_verification_obligation)
    foreign_claim = create(:layered_verification_correspondence_claim)
    foreign_run = create(:agent_run)

    mismatched_claim = build(:layered_verification_check_result, obligation: obligation,
      correspondence_claim: foreign_claim)

    expect(mismatched_claim).to be_invalid
    expect(mismatched_claim.errors[:correspondence_claim]).to include("must belong to the same obligation")

    mismatched_run = build(:layered_verification_check_result, obligation: obligation, agent_run: foreign_run)

    expect(mismatched_run).to be_invalid
    expect(mismatched_run.errors[:agent_run]).to include("must belong to the same project")
  end
end
