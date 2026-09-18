# frozen_string_literal: true

require "rails_helper"

# @spec INTENT-CONFORMANCE-004
RSpec.describe IntentConformance::RecordDecision do
  let(:project) { create(:project) }
  let(:issue) { create(:issue, :pull_request, project: project) }
  let(:verdict) { create(:intent_conformance_verdict, :material_drift, issue: issue, pr_head_sha: "sha1") }
  let(:actor) { create(:user, account: project.account) }

  describe ".call" do
    it "records a decision scoped to the verdict's issue and head_sha" do
      result = described_class.call(verdict: verdict, action: "bounded_exception", reason: "Implementation detail only.", actor: actor)

      expect(result).to be_success
      expect(result.decision).to have_attributes(
        issue: issue,
        verdict: verdict,
        action: "bounded_exception",
        head_sha: "sha1",
        reason: "Implementation detail only.",
        actor: actor
      )
    end

    it "fails when the action is not one of the defined actions" do
      result = described_class.call(verdict: verdict, action: "not_a_real_action", reason: "reason", actor: actor)

      expect(result).not_to be_success
      expect(result.error).to be_present
      expect(result.decision).to be_nil
    end

    it "fails when the reason is blank" do
      result = described_class.call(verdict: verdict, action: "fix_pr", reason: "", actor: actor)

      expect(result).not_to be_success
      expect(result.error).to be_present
    end

    it "logs a structured event on success" do
      allow(Rails.logger).to receive(:info)

      described_class.call(verdict: verdict, action: "design_amendment", reason: "Scope should change.", actor: actor)

      expect(Rails.logger).to have_received(:info).with(
        hash_including(message: "intent_conformance.decision_recorded", action: "design_amendment")
      )
    end
  end
end
