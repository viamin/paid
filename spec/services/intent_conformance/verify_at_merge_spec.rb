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

    # @spec INTENT-CONFORMANCE-REVIEW-006
    context "when the verdict is authored by IntentConformance::ReviewRun" do
      let(:github_client) { instance_double(GithubClient) }
      let(:pr_base) { double("pr_base", sha: "base_sha") } # rubocop:disable RSpec/VerifiedDoubles
      let(:pr_data) { double("pr_data", base: pr_base) } # rubocop:disable RSpec/VerifiedDoubles
      let(:file_content) { "# RDR-999\n\nThe widget SHALL always be blue." }
      let(:comparison) do
        {
          files: [
            { filename: "app/models/widget.rb", status: "modified", additions: 3, deletions: 1, patch: "@@ -1,2 +1,3 @@\n widget code" }
          ]
        }
      end
      let(:superseding_head) { "head_after_push" }

      before do
        feature_intent.update!(design_document_paths: [ "docs/rdrs/RDR-999-example.md" ])
        allow(project).to receive(:client).and_return(github_client)
        allow(project).to receive_messages(full_name: "acme/widgets", client: github_client)
        allow(github_client).to receive(:file_content)
          .with("acme/widgets", path: "docs/rdrs/RDR-999-example.md", ref: "rev1")
          .and_return(file_content)
        allow(github_client).to receive(:pull_request).with("acme/widgets", issue.github_number).and_return(pr_data)
        allow(github_client).to receive(:compare_summary)
          .with("acme/widgets", "base_sha", current_head).and_return(comparison)
        allow(github_client).to receive(:compare_summary)
          .with("acme/widgets", "base_sha", superseding_head).and_return(comparison)
        allow(AgentHarness).to receive(:send_message).and_return(
          instance_double(AgentHarness::Response,
            success?: true,
            output: { outcome: "within_scope", cited_design_claims: [], cited_diff_locations: [], reasoning_summary: "OK" }.to_json,
            model: "claude-sonnet-4-6")
        )
      end

      it "unblocks merge for the exact head ReviewRun was invoked against" do
        verdict = IntentConformance::ReviewRun.call(project: project, issue: issue, pr_head_sha: current_head)

        expect(verdict).to be_within_scope
        expect(verdict.pr_head_sha).to eq(current_head)
        expect(call).to be_nil
      end

      it "is structurally stale after a superseding push (ReviewRun records a new verdict for the new head)" do
        IntentConformance::ReviewRun.call(project: project, issue: issue, pr_head_sha: current_head)
        IntentConformance::ReviewRun.call(project: project, issue: issue, pr_head_sha: superseding_head)

        result = described_class.call(project: project, issue: issue, pr_head_sha: current_head)

        expect(result.reason_code).to eq(described_class::REASON_VERDICT_STALE)
      end
    end
  end
end
