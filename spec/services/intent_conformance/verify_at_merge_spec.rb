# frozen_string_literal: true

require "rails_helper"

# @spec INTENT-MERGE-GUARD-001
# @spec INTENT-MERGE-GUARD-002
# @spec INTENT-MERGE-GUARD-003
# @spec INTENT-MERGE-GUARD-004
# @spec INTENT-MERGE-GUARD-005
# @spec INTENT-MERGE-GUARD-006
# @spec INTENT-MERGE-GUARD-007
# @spec INTENT-MERGE-GUARD-008
RSpec.describe IntentConformance::VerifyAtMerge do
  let(:project) { create(:project) }
  let(:issue) { create(:issue, :pull_request, project: project) }
  let(:feature_intent) { create(:feature_intent, project: project, status: "released", approved_design_revision: "rev1") }
  let(:current_head) { "head_current" }

  def call
    described_class.call(project: project, issue: issue, pr_head_sha: current_head)
  end

  before do
    project.account.tenant_setting!.update!(features: { "approved_intent_amendments" => true })
  end

  # @spec INTENT-MERGE-GUARD-001
  context "when the issue is not linked to a feature intent" do
    it "is a no-op regardless of verdict state" do
      expect(call).to be_nil
    end
  end

  # @spec INTENT-MERGE-GUARD-001
  context "when the project has not opted into the rollout flag" do
    before do
      create(:feature_intent_issue, feature_intent: feature_intent, issue: issue)
      project.account.tenant_setting!.update!(features: { "approved_intent_amendments" => false })
    end

    it "is a no-op even without a verdict" do
      expect(call).to be_nil
    end
  end

  context "when the issue is linked to a feature intent under the rollout flag" do
    before { create(:feature_intent_issue, feature_intent: feature_intent, issue: issue) }

    # @spec INTENT-MERGE-GUARD-004
    context "when the feature intent is revising (design amendment open)" do
      before { feature_intent.update!(status: "revising") }

      it "blocks merge" do
        result = call

        expect(result.reason_code).to eq(described_class::REASON_REVISING)
      end
    end

    # @spec INTENT-MERGE-GUARD-005
    context "when the issue is paused by an active design-amendment hold" do
      before do
        amendment = create(:design_amendment, project: project, feature_intent: feature_intent)
        create(:design_amendment_pause, design_amendment: amendment, issue: issue, status: "held")
        create(:intent_conformance_verdict, project: project, issue: issue,
          pr_head_sha: current_head, approved_design_revision: "rev1", outcome: "within_scope")
      end

      it "blocks merge even with a fresh within_scope verdict" do
        result = call

        expect(result.reason_code).to eq(described_class::REASON_PAUSED)
      end
    end

    # @spec INTENT-MERGE-GUARD-002
    context "when no verdict has ever been recorded" do
      it "blocks merge (fail closed)" do
        result = call

        expect(result.reason_code).to eq(described_class::REASON_VERDICT_MISSING)
      end
    end

    # @spec INTENT-MERGE-GUARD-003
    context "when a push happened after the verdict was recorded" do
      before do
        create(:intent_conformance_verdict, project: project, issue: issue,
          pr_head_sha: "head_before_push", approved_design_revision: "rev1", outcome: "within_scope")
      end

      it "blocks merge because the verdict's head is stale" do
        result = call

        expect(result.reason_code).to eq(described_class::REASON_VERDICT_STALE)
      end
    end

    # @spec INTENT-MERGE-GUARD-004
    context "when a design amendment merged a new revision after the verdict was recorded" do
      before do
        create(:intent_conformance_verdict, project: project, issue: issue,
          pr_head_sha: current_head, approved_design_revision: "rev0_superseded", outcome: "within_scope")
      end

      it "blocks merge because the verdict's approved revision is stale" do
        result = call

        expect(result.reason_code).to eq(described_class::REASON_VERDICT_STALE)
      end
    end

    # @spec INTENT-MERGE-GUARD-006
    context "when the current verdict is within_scope" do
      before do
        create(:intent_conformance_verdict, project: project, issue: issue,
          pr_head_sha: current_head, approved_design_revision: "rev1", outcome: "within_scope")
      end

      it "allows merge to proceed to the project's other preconditions" do
        expect(call).to be_nil
      end
    end

    # @spec INTENT-MERGE-GUARD-007
    %w[material_drift uncertain not_evaluated].each do |outcome|
      context "when the current verdict is #{outcome}" do
        before do
          create(:intent_conformance_verdict, project: project, issue: issue,
            pr_head_sha: current_head, approved_design_revision: "rev1", outcome: outcome)
        end

        it "blocks merge by default" do
          result = call

          expect(result.reason_code).to eq(outcome)
        end

        it "allows merge when a human implementation exception is bound to the exact same head" do
          create(:intent_conformance_resolution,
            project: project, issue: issue, pr_head_sha: current_head, resolution_type: "implementation_exception")

          expect(call).to be_nil
        end

        it "still blocks merge when the exception is bound to a different head" do
          create(:intent_conformance_resolution,
            project: project, issue: issue, pr_head_sha: "some_other_head", resolution_type: "implementation_exception")

          result = call

          expect(result.reason_code).to eq(outcome)
        end

        it "does not accept a require_within_scope resolution as authorizing merge" do
          create(:intent_conformance_resolution,
            project: project, issue: issue, pr_head_sha: current_head, resolution_type: "require_within_scope")

          result = call

          expect(result.reason_code).to eq(outcome)
        end
      end
    end
  end
end
