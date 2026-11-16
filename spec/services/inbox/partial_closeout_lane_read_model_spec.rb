# frozen_string_literal: true

require "rails_helper"

# Shared-projection read path for the partial-closeout lane: one reader backs
# the list, the nav badge, and the filter matrix, and an Inbox index render
# performs no live admission evaluation for a project with a successful
# checkpoint (RDR-081).
RSpec.describe "Partial-closeout lane read model" do # @spec PARTIAL-CLOSEOUT-043
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
  let(:candidate_source) { Automation::Strategies::AutoPick::DefaultCandidateSource }

  def create_stalled_issue(github_number:, merged_pr_number: 14, **attrs)
    issue = create(:issue, project: project, github_number: github_number, paid_state: "in_progress", **attrs)
    create(
      :issue,
      :pull_request,
      project: project,
      github_number: merged_pr_number,
      github_state: "closed",
      pr_review_phase: "merged",
      parent_issue_id: issue.id,
      created_at: 2.days.ago
    )
    issue
  end

  before do
    FeatureFlags.enable!(Issues::StalledCloseoutProjection::FLAG, project: project)
    allow(GithubClient).to receive(:new).and_return(instance_double(GithubClient, issue_comments: []))
  end

  describe "Inbox index render" do
    it "evaluates no eligible_scope for projects with a successful projection checkpoint" do
      create_stalled_issue(github_number: 31)
      Issues::StalledCloseoutProjection.recompute(project)
      allow(candidate_source).to receive(:eligible_scope).and_call_original
      allow(candidate_source).to receive(:partial_closeout_eligibility).and_call_original

      entries = Inbox::Queue.call(user: user)
      Rails.cache.clear
      Inbox::Count.call(user: user)
      Rails.cache.clear
      Inbox::Availability.call(user: user).total_count

      expect(entries.map(&:kind)).to include(Inbox::Queue::PARTIAL_CLOSEOUT_KIND)
      expect(candidate_source).not_to have_received(:eligible_scope)
      expect(candidate_source).not_to have_received(:partial_closeout_eligibility)
    end

    it "keeps the live path for a project without a successful checkpoint" do
      create_stalled_issue(github_number: 32)
      allow(candidate_source).to receive(:partial_closeout_eligibility).and_call_original

      entries = Inbox::Queue.call(user: user, kind: Inbox::Queue::PARTIAL_CLOSEOUT_KIND)

      expect(entries.size).to eq(1)
      expect(candidate_source).to have_received(:partial_closeout_eligibility)
    end
  end

  describe "consumer agreement" do
    it "reports the same lane membership for the list, nav badge, and filter matrix" do
      create_stalled_issue(github_number: 33)
      create_stalled_issue(github_number: 34, merged_pr_number: 15)
      Issues::StalledCloseoutProjection.recompute(project)
      Rails.cache.clear

      list = Inbox::Queue.call(user: user, kind: Inbox::Queue::PARTIAL_CLOSEOUT_KIND)
      availability = Inbox::Availability.call(user: user)
      badge = Inbox::Count.call(user: user)

      expect(list.size).to eq(2)
      expect(availability.project_ids_for(Inbox::Queue::PARTIAL_CLOSEOUT_KIND)).to eq([project.id])
      expect(availability.kind_counts.fetch(Inbox::Queue::PARTIAL_CLOSEOUT_KIND)).to eq(2)
      # The partial-closeout lane is the only populated lane in this fixture,
      # so the badge total equals the shared projection's membership size.
      expect(badge).to eq(list.size)
    end
  end

  describe "operator actions from a projected entry" do
    it "still decides continuation through the live scoped preflight with the real blocker" do
      issue = create_stalled_issue(github_number: 35)
      Issues::StalledCloseoutProjection.recompute(project)

      # The projection goes stale: an explicit pause lands after the last
      # recomputation, so the lane still shows the projected entry.
      issue.update_columns(paused: true)
      expect(Inbox::Queue.call(user: user, kind: Inbox::Queue::PARTIAL_CLOSEOUT_KIND).map(&:issue))
        .to contain_exactly(issue)

      result = Issues::RequestContinuation.call(issue: issue.reload, actor: user, reason: "resume the remaining work")

      expect(result).not_to be_success
      expect(result.message).to include("pause")
      expect(result.agent_run).to be_nil
      expect(IssueContinuationRequest.where(issue: issue)).to be_empty
    end
  end
end
