# frozen_string_literal: true

require "rails_helper"

RSpec.describe Issues::ReconcilePullRequestSource do
  let(:project) { create(:project) }

  it "links a synced PR to the one source issue recorded by its completed run" do # @spec EAGER-QUEUE-009
    source = create(:issue, project: project)
    pull_request = create(:issue, :pull_request, project: project, github_number: 42, parent_issue_id: nil)
    create(:agent_run, :completed, project: project, issue: source, goal: "create_pr", pull_request_number: 42)

    described_class.call(pull_request: pull_request)

    expect(pull_request.reload.parent_issue).to eq(source)
  end

  it "links a PR to the source recorded by a run that failed after publishing it" do # @spec EAGER-QUEUE-009
    # Review follow-up on #4039: reserve_pull_request! persists the PR
    # number before complete! runs, so a completion-gate failure marks the
    # run failed while its PR is already open on GitHub. The recorded
    # number is the source evidence, not the terminal status.
    source = create(:issue, project: project)
    pull_request = create(:issue, :pull_request, project: project, github_number: 42, parent_issue_id: nil)
    create(:agent_run, :failed, project: project, issue: source, goal: "create_pr", pull_request_number: 42)

    described_class.call(pull_request: pull_request)

    expect(pull_request.reload.parent_issue).to eq(source)
  end

  it "does not guess when runs for the same PR disagree about the source" do # @spec EAGER-QUEUE-010
    first_source = create(:issue, project: project)
    second_source = create(:issue, project: project)
    pull_request = create(:issue, :pull_request, project: project, github_number: 42, parent_issue_id: nil)
    create(:agent_run, :completed, project: project, issue: first_source, goal: "create_pr", pull_request_number: 42)
    create(:agent_run, :completed, project: project, issue: second_source, goal: "create_pr", pull_request_number: 42)

    described_class.call(pull_request: pull_request)

    expect(pull_request.reload.parent_issue_id).to be_nil
  end

  it "preserves a PR follow-up run's original source issue" do # @spec EAGER-QUEUE-010
    source = create(:issue, project: project)
    follow_up_pr = create(:issue, :pull_request, project: project, github_number: 41, parent_issue: source)
    pull_request = create(:issue, :pull_request, project: project, github_number: 42, parent_issue_id: nil)
    create(:agent_run, :completed, project: project, issue: follow_up_pr, goal: "create_pr", pull_request_number: 42)

    described_class.call(pull_request: pull_request)

    expect(pull_request.reload.parent_issue).to eq(source)
  end
end
