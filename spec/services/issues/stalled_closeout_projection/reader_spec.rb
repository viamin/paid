# frozen_string_literal: true

require "rails_helper"

# RDR-081 / PARTIAL-CLOSEOUT-043: the lane's list, nav-badge count, and filter
# matrix read one shared projection reader, agree on membership, and evaluate no
# `eligible_scope` on the request path for projects with a successful
# checkpoint. Projects without one stay on the live path, and operator actions
# from projected entries remain decided by the live scoped preflight.
RSpec.describe Issues::StalledCloseoutProjection::Reader do # @spec PARTIAL-CLOSEOUT-043
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
  let(:issue) { create(:issue, project: project, github_state: "open", paid_state: "in_progress") }
  let(:candidate_source) { Automation::Strategies::AutoPick::DefaultCandidateSource }

  def merged_pr_row(number:, parent_issue_id:)
    create(
      :issue,
      :pull_request,
      project: project,
      github_number: number,
      github_state: "closed",
      pr_review_phase: "merged",
      parent_issue_id: parent_issue_id
    )
  end

  def track_eligible_scope_evaluations
    evaluations = []
    allow(candidate_source).to receive(:partial_closeout_eligibility).and_wrap_original do |original, *args, **kwargs|
      evaluations << :partial_closeout_eligibility
      original.call(*args, **kwargs)
    end
    allow(candidate_source).to receive(:eligible_scope).and_wrap_original do |original, *args, **kwargs|
      evaluations << :eligible_scope
      original.call(*args, **kwargs)
    end
    evaluations
  end

  before do
    merged_pr_row(number: 21, parent_issue_id: issue.id)
  end

  describe "with a successful projection checkpoint" do
    before do
      FeatureFlags.enable!(:partial_closeout_lane_read_model, project: project)
      Issues::StalledCloseoutProjection.recompute!(project)
    end

    it "reports the same lane membership from the queue list, badge count, and filter matrix" do
      entries = Inbox::Queue.call(user: user, kind: Inbox::Queue::PARTIAL_CLOSEOUT_KIND)
      count = Inbox::Count.call(user: user)
      per_project = Inbox::Availability.call(user: user).project_ids_for(Inbox::Queue::PARTIAL_CLOSEOUT_KIND)

      expect(entries.map(&:issue)).to contain_exactly(issue)
      expect(count).to eq(1)
      expect(per_project).to contain_exactly(project.id)
      expect(entries.sole.closeout_status).to be_stalled
      expect(entries.sole.summary_text).to include("#21")
    end

    it "evaluates no eligible_scope on the request path" do
      evaluations = track_eligible_scope_evaluations

      expect { Inbox::Queue.call(user: user, kind: Inbox::Queue::PARTIAL_CLOSEOUT_KIND) }.not_to raise_error
      expect { Inbox::Count.call(user: user) }.not_to raise_error
      expect { Inbox::Availability.call(user: user).project_ids_for(Inbox::Queue::PARTIAL_CLOSEOUT_KIND) }
        .not_to raise_error

      expect(evaluations).to be_empty
    end

    it "still decides an operator action from a projected lane entry with the live scoped preflight" do
      # The projection is now stale: an explicit pause landed after the
      # recomputation and no trigger has run yet.
      issue.update_columns(paused: true, updated_at: Time.current)

      result = Issues::RequestContinuation.call(
        issue: issue, actor: user, reason: "Continue the remaining closeout work."
      )

      expect(result).not_to be_success
      expect(result.code).to eq(:operator_pause)
      expect(result.message).to include("pause is active")
    end
  end

  describe "without a successful checkpoint" do
    it "stays on the live path when the project is enrolled but unevaluated" do
      FeatureFlags.enable!(:partial_closeout_lane_read_model, project: project)
      evaluations = track_eligible_scope_evaluations

      entries = Inbox::Queue.call(user: user, kind: Inbox::Queue::PARTIAL_CLOSEOUT_KIND)

      expect(entries.map(&:issue)).to contain_exactly(issue)
      expect(evaluations).not_to be_empty
    end

    it "keeps live admission when the flag is disabled" do
      evaluations = track_eligible_scope_evaluations

      entries = Inbox::Queue.call(user: user, kind: Inbox::Queue::PARTIAL_CLOSEOUT_KIND)

      expect(entries.map(&:issue)).to contain_exactly(issue)
      expect(evaluations).not_to be_empty
    end
  end
end
