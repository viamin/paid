# frozen_string_literal: true

require "rails_helper"

RSpec.describe AgentRuns::RefreshDependencyBottleneckPriority do # @spec QUEUE-TIER-011
  it "promotes a fresh prerequisite ahead of recurring PR work without changing its identity" do
    project = create(:project)
    prerequisite = create(:issue, project:)
    dependent = create(:issue, project:)
    IssueDependency.create!(issue: dependent, depends_on_issue: prerequisite)
    create(:issue, project:, is_pull_request: true, github_state: "open", parent_issue: dependent)
    bottleneck = create(:agent_run, :queued, :automatic, project:, issue: prerequisite, goal: "create_pr", auto_pick: true)
    review = create(:agent_run, :queued, :automatic, :review_goal, project:, source_pull_request_number: 42)
    original = bottleneck.attributes.slice("trigger_type", "initiating_user_id", "queue_entered_at", "continuation_request_id")

    described_class.call

    expect(bottleneck.reload.dependency_bottleneck_priority_requested_at).to be_present
    expect(bottleneck.attributes.slice(*original.keys)).to eq(original)
    expect(AgentRun.next_queued_run).to eq(bottleneck)
    expect(review.reload.queue_priority_tier).to start_with("pr_")
  end

  it "clears the marker when the synchronized delivery evidence is stale" do
    project = create(:project)
    prerequisite = create(:issue, project:)
    dependent = create(:issue, project:)
    IssueDependency.create!(issue: dependent, depends_on_issue: prerequisite)
    pull_request = create(:issue, project:, is_pull_request: true, github_state: "open", parent_issue: dependent)
    bottleneck = create(:agent_run, :queued, :automatic, project:, issue: prerequisite, goal: "create_pr", auto_pick: true)

    described_class.call
    pull_request.update!(github_state: "closed")
    described_class.call

    expect(bottleneck.reload.dependency_bottleneck_priority_requested_at).to be_nil
  end

  it "does not promote unrelated work or cross-project dependency facts" do
    project = create(:project)
    other_project = create(:project)
    issue = create(:issue, project:)
    unrelated = create(:agent_run, :queued, :automatic, project:, issue:, goal: "create_pr", auto_pick: true)
    foreign_issue = create(:issue, project: other_project)
    create(:issue, project: other_project, is_pull_request: true, github_state: "open", parent_issue: foreign_issue)

    described_class.call

    expect(unrelated.reload.dependency_bottleneck_priority_requested_at).to be_nil
  end
end
