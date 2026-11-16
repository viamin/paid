# frozen_string_literal: true

require "rails_helper"

RSpec.describe Issues::StalledCloseoutProjection do # @spec PARTIAL-CLOSEOUT-042
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:project) do
    create(
      :project,
      account: account,
      created_by: user,
      auto_pick_enabled: true,
      active: true,
      auto_merge_mode: "all",
      owner_reviewer_login: "viamin",
      owner: "acme",
      repo: "alpha"
    )
  end
  let(:other_account) { create(:account) }
  let(:other_user) { create(:user, account: other_account) }
  let(:other_project) do
    create(
      :project,
      account: other_account,
      created_by: other_user,
      auto_pick_enabled: true,
      active: true,
      owner: "other",
      repo: "beta"
    )
  end

  def create_stalled_issue(project_record: project, github_number:, merged_pr_number: 14, **attrs)
    issue = create(:issue, project: project_record, github_number: github_number, paid_state: "in_progress", **attrs)
    create(
      :issue,
      :pull_request,
      project: project_record,
      github_number: merged_pr_number,
      github_state: "closed",
      pr_review_phase: "merged",
      parent_issue_id: issue.id,
      created_at: 2.days.ago
    )
    issue
  end

  before do
    TenantContext.with_system_access { FeatureFlags.enable!(described_class::FLAG, project: project) }
  end

  describe ".recompute" do
    it "persists the live admission result as stall rows under an atomic project checkpoint" do
      issue = create_stalled_issue(github_number: 11)

      result = described_class.recompute(project)

      expect(result).to be_success
      checkpoint = StallProjectionCheckpoint.find_by(project: project)
      expect(checkpoint.computed_at).to be_present
      expect(checkpoint.generation).to be_positive
      expect(checkpoint.input_watermark).to be_present
      stall = StallProjectionStall.where(project: project).sole
      expect(stall.issue).to eq(issue)
      expect(stall.projection_generation).to eq(checkpoint.generation)
      expect(stall.evidence_digest).to eq(Issues::CloseoutEvidence.call(issue).digest)
      expect(stall.status).to be_present
      expect(stall.blockers).to be_an(Array)
    end

    it "renders the same entry shape as the live lane from the persisted rows" do
      issue = create_stalled_issue(github_number: 12)

      described_class.recompute(project)

      pairs = described_class.pairs([project])
      expect(pairs.map(&:issue)).to eq([issue])
      status = pairs.first.status
      expect(status).to be_stalled
      expect(status.outcome).to be_present
      expect(status.reason).to include("merged partial PR #14")
      expect(status.evidence.terminal_at).to be_present
      expect(status.evidence.digest).to eq(Issues::CloseoutEvidence.call(issue).digest)
      expect(status.evidence.merged_prs.map(&:number)).to eq([14])
      expect(status.blockers).to be_an(Array)
    end

    it "removes a projected stall the live admission scope no longer holds" do
      issue = create_stalled_issue(github_number: 13)
      described_class.recompute(project)

      issue.update!(github_state: "closed", closed_at: Time.current)
      described_class.recompute(project)

      expect(StallProjectionStall.where(project: project)).to be_empty
      expect(described_class.pairs([project])).to be_empty
    end

    it "removes the entry when a continuation request opens and returns it after the run finished" do
      issue = create_stalled_issue(github_number: 14)
      described_class.recompute(project)
      request = create(:issue_continuation_request, issue: issue, project: project, requested_by: user)

      described_class.recompute(project)

      expect(StallProjectionStall.where(project: project)).to be_empty
      request.update!(status: "consumed", closed_at: Time.current)

      described_class.recompute(project)

      expect(StallProjectionStall.where(project: project).map(&:issue_id)).to eq([issue.id])
    end

    it "distinguishes an evaluated project with no stalls from an unevaluated project" do
      result = described_class.recompute(project)

      expect(result).to be_success
      checkpoint = StallProjectionCheckpoint.find_by(project: project)
      expect(checkpoint.computed_at).to be_present
      expect(StallProjectionStall.where(project: project)).to be_empty
    end

    it "keeps the previous projection and records bounded failure metadata when recomputation fails" do
      issue = create_stalled_issue(github_number: 15)
      described_class.recompute(project)
      checkpoint = StallProjectionCheckpoint.find_by(project: project)
      previous_generation = checkpoint.generation
      previous_computed_at = checkpoint.computed_at
      allow(Issues::StalledCloseouts).to receive(:pairs_for).and_raise(RuntimeError, "eligibility exploded")

      result = described_class.recompute(project)

      expect(result).not_to be_success
      expect(result.failure).to include("error_class")
      checkpoint.reload
      expect(checkpoint.generation).to eq(previous_generation)
      expect(checkpoint.computed_at).to eq(previous_computed_at)
      expect(checkpoint.last_failure_at).to be_present
      expect(checkpoint.last_failure).to include("error_class" => "RuntimeError")
      expect(StallProjectionStall.where(project: project).map(&:issue_id)).to eq([issue.id])
      expect(described_class.pairs([project]).map(&:issue)).to eq([issue])
    end

    it "never mutates paid_state and never grants a continuation" do
      issue = create_stalled_issue(github_number: 16)

      expect { described_class.recompute(project) }.not_to change { issue.reload.paid_state }
      expect(IssueContinuationRequest.where(issue: issue)).to be_empty
    end
  end

  describe ".pairs tenant isolation" do
    it "never returns another account's projected stalls", :tenant_isolation do
      TenantContext.with_system_access do
        @mine = create_stalled_issue(github_number: 17)
        @theirs = create_stalled_issue(project_record: other_project, github_number: 18, merged_pr_number: 15)
        FeatureFlags.enable!(described_class::FLAG, project: other_project)
        described_class.recompute(project)
        described_class.recompute(other_project)
      end

      pairs = TenantContext.with(account) { described_class.pairs([project, other_project]) }

      expect(pairs.map(&:issue)).to contain_exactly(@mine)
      expect(pairs.map(&:issue)).not_to include(@theirs)
    end
  end

  describe "rollout guard fallback" do
    it "keeps the live path while the flag is disabled" do
      FeatureFlags.disable!(described_class::FLAG, project: project)
      issue = create_stalled_issue(github_number: 19)
      allow(Automation::Strategies::AutoPick::DefaultCandidateSource).to receive(
        :partial_closeout_eligibility
      ).and_call_original

      pairs = described_class.pairs([project])

      expect(pairs.map(&:issue)).to eq([issue])
      expect(Automation::Strategies::AutoPick::DefaultCandidateSource).to have_received(:partial_closeout_eligibility)
    end

    it "keeps the live path until a first successful checkpoint commits" do
      issue = create_stalled_issue(github_number: 20)
      allow(Issues::StalledCloseouts).to receive(:pairs_for).and_raise(RuntimeError, "initial backfill failed")
      expect(described_class.recompute(project)).not_to be_success
      allow(Issues::StalledCloseouts).to receive(:pairs_for).and_call_original

      pairs = described_class.pairs([project])

      expect(pairs.map(&:issue)).to eq([issue])
      # The unevaluated project stays on live admission, not its failed rows.
      expect(StallProjectionStall.where(project: project)).to be_empty
    end
  end

  describe ".due?" do
    it "is due without a successful checkpoint and when admission-relevant inputs changed" do
      expect(described_class).to be_due(project)

      issue = create_stalled_issue(github_number: 21)
      described_class.recompute(project)

      expect(described_class).not_to be_due(project)

      create(:agent_run, :queued, project: project, issue: issue)

      expect(described_class).to be_due(project)
    end
  end
end
