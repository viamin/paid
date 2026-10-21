# frozen_string_literal: true

require "rails_helper"

RSpec.describe RemediationDecision do
  let(:account) { create(:account) }

  describe ".pending_outcome" do
    # @spec RUN-OBSTACLE-005
    it "retries insufficient evidence only while the observation window remains open" do
      open_decision = insufficient_evidence_decision(applied_at: 30.minutes.ago)
      closed_decision = insufficient_evidence_decision(applied_at: 2.hours.ago)
      unevaluated_decision = unevaluated_decision(applied_at: 2.hours.ago)
      pending_outcomes = described_class.pending_outcome

      expect(pending_outcomes).to include(open_decision, unevaluated_decision)
      expect(pending_outcomes).not_to include(closed_decision)
    end
  end

  describe "#dismiss!" do
    # @spec RUN-OBSTACLE-003
    it "rejects dismissal after a correction has been applied" do
      decision = remediation_decision(applied_at: 1.hour.ago, outcome: nil)

      expect { decision.dismiss!(reason: "No longer needed") }
        .to raise_error(ActiveRecord::RecordInvalid)
      expect(decision.reload).to have_attributes(status: "applied", dismissal_reason: nil)
    end
  end

  def insufficient_evidence_decision(applied_at:)
    remediation_decision(applied_at:, outcome: "insufficient_evidence")
  end

  def unevaluated_decision(applied_at:)
    remediation_decision(applied_at:, outcome: nil)
  end

  def remediation_decision(applied_at:, outcome:)
    create(
      :remediation_decision,
      account: account,
      status: "applied",
      applied_at: applied_at,
      outcome: outcome,
      proposal_context: { "window_hours" => 1 }
    )
  end
end
