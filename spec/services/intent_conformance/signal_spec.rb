# frozen_string_literal: true

require "rails_helper"

# @spec INTENT-CONFORMANCE-002 @spec INTENT-CONFORMANCE-003 @spec INTENT-CONFORMANCE-005
RSpec.describe IntentConformance::Signal do
  let(:project) { create(:project) }
  let(:issue) { create(:issue, :pull_request, project: project) }

  describe ".ok?" do
    it "is true when enforcement is disabled for the project, regardless of verdict state" do
      create(:intent_conformance_verdict, :material_drift, issue: issue, pr_head_sha: "sha1")

      expect(described_class.ok?(project: project, issue: issue, head_sha: "sha1")).to be(true)
    end

    context "when enforcement is enabled for the project" do
      before { FeatureFlags.enable!(:intent_conformance_enforcement, project: project) }

      it "is true when the head_sha is blank" do
        expect(described_class.ok?(project: project, issue: issue, head_sha: nil)).to be(true)
      end

      it "is false when no verdict exists for the current head" do
        expect(described_class.ok?(project: project, issue: issue, head_sha: "sha1")).to be(false)
      end

      it "is true when the current head has a within_scope verdict" do
        create(:intent_conformance_verdict, issue: issue, pr_head_sha: "sha1")

        expect(described_class.ok?(project: project, issue: issue, head_sha: "sha1")).to be(true)
      end

      it "is false when the current head's verdict is material_drift" do
        create(:intent_conformance_verdict, :material_drift, issue: issue, pr_head_sha: "sha1")

        expect(described_class.ok?(project: project, issue: issue, head_sha: "sha1")).to be(false)
      end

      it "is false when the current head's verdict is uncertain" do
        create(:intent_conformance_verdict, :uncertain, issue: issue, pr_head_sha: "sha1")

        expect(described_class.ok?(project: project, issue: issue, head_sha: "sha1")).to be(false)
      end

      it "is false when the current head's verdict is not_evaluated" do
        create(:intent_conformance_verdict, :not_evaluated, issue: issue, pr_head_sha: "sha1")

        expect(described_class.ok?(project: project, issue: issue, head_sha: "sha1")).to be(false)
      end

      it "is true when a bounded exception matches the current head, even without a within_scope verdict" do
        create(:intent_conformance_verdict, :material_drift, issue: issue, pr_head_sha: "sha1")
        create(:intent_conformance_decision, :bounded_exception, issue: issue, head_sha: "sha1")

        expect(described_class.ok?(project: project, issue: issue, head_sha: "sha1")).to be(true)
      end

      it "is false when a bounded exception exists only for a different (older) head" do
        create(:intent_conformance_verdict, :material_drift, issue: issue, pr_head_sha: "sha2")
        create(:intent_conformance_decision, :bounded_exception, issue: issue, head_sha: "sha1")

        expect(described_class.ok?(project: project, issue: issue, head_sha: "sha2")).to be(false)
      end
    end
  end
end
