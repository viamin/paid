# frozen_string_literal: true

require "rails_helper"

RSpec.describe Issues::StalledCloseoutProjection do # @spec PARTIAL-CLOSEOUT-043
  # The Inbox readers (Queue list, Count badge, Availability filter matrix)
  # consume the projection through the shared reader, so this spec exercises
  # the lane's display path end to end with a committed checkpoint.
  let(:account) { create(:account) }
  let(:owner) { create(:user, account:) }
  let(:project) do
    create(
      :project,
      account: account,
      created_by: owner,
      auto_pick_enabled: true,
      active: true,
      owner: "acme",
      repo: "alpha"
    )
  end
  let(:issue) { create(:issue, project: project, github_state: "open", paid_state: "in_progress") }

  def seed_stall(number:, parent: issue)
    create(
      :issue,
      :pull_request,
      project: parent.project,
      github_number: number,
      github_state: "closed",
      pr_review_phase: "merged",
      parent_issue_id: parent.id
    )
  end

  before do
    FeatureFlags.enable!(:partial_closeout_lane_read_model, project:)
    seed_stall(number: 12)
    described_class.recompute(project)
    project.reload
  end

  it "reports the same lane membership from Queue, Count, and Availability" do
    entries = Inbox::Queue.call(user: owner, kind: Inbox::Queue::PARTIAL_CLOSEOUT_KIND)
    availability = Inbox::Availability.new(user: owner).kind_counts

    expect(entries.map(&:id)).to eq([ "#{Inbox::Queue::PARTIAL_CLOSEOUT_KIND}:#{issue.id}" ])
    expect(availability[Inbox::Queue::PARTIAL_CLOSEOUT_KIND]).to eq(entries.size)
    expect(Inbox::Count.call(user: owner)).to eq(entries.size)
  end

  it "issues no eligible_scope evaluation on the request path once every visible project is checkpointed" do
    allow(Automation::Strategies::AutoPick::DefaultCandidateSource).to receive(:eligible_scope)
      .and_raise(StandardError, "eligible_scope must not run on the Inbox request path")

    expect(Inbox::Queue.call(user: owner).map(&:id))
      .to eq([ "#{Inbox::Queue::PARTIAL_CLOSEOUT_KIND}:#{issue.id}" ])
    expect(Inbox::Availability.new(user: owner).kind_counts[Inbox::Queue::PARTIAL_CLOSEOUT_KIND]).to eq(1)
    expect(Inbox::Count.call(user: owner)).to eq(1)
  end

  it "renders the projected entry with the persisted reason and evidence" do
    entry = Inbox::Queue.call(user: owner, kind: Inbox::Queue::PARTIAL_CLOSEOUT_KIND).first

    live_status = Issues::CloseoutStatus.call(issue)
    expect(entry.closeout_status.reason).to eq(live_status.reason)
    expect(entry.closeout_status.evidence.merged_prs.map(&:number)).to contain_exactly(12)
    expect(entry.waiting_since).to be_present
    expect(entry.summary).to eq("#{live_status.outcome} #{live_status.reason}")
  end

  it "keeps an operator action from a projected entry decided by the live scoped preflight" do
    issue.update_columns(paused: true)

    result = Issues::RequestContinuation.call(issue: issue, actor: owner, reason: "Continue past the merged partial PR.")

    expect(result).not_to be_success
    expect(result.message).to include("pause")
    expect(IssueContinuationRequest.open_for_issue(issue)).to be_nil
  end
end
