# frozen_string_literal: true

require "rails_helper"

RSpec.describe Issues::ReconcilePullRequestSource do
  let(:project) { create(:project) }

  it "repairs an unlinked PR from one recorded non-PR source issue" do # @spec EAGER-QUEUE-009
    source = create(:issue, project: project)
    pull_request = create(:issue, :pull_request, project: project, github_number: 42, parent_issue_id: nil)
    create(:agent_run, :completed, project: project, issue: source,
      goal: "create_pr", pull_request_number: 42)

    described_class.call(pull_request)

    expect(pull_request.reload.parent_issue_id).to eq(source.id)
  end

  it "does not guess when historical producer records conflict" do # @spec EAGER-QUEUE-009
    first_source = create(:issue, project: project)
    second_source = create(:issue, project: project)
    pull_request = create(:issue, :pull_request, project: project, github_number: 42, parent_issue_id: nil)
    [ first_source, second_source ].each do |source|
      create(:agent_run, :completed, project: project, issue: source,
        goal: "create_pr", pull_request_number: 42)
    end

    described_class.call(pull_request)

    expect(pull_request.reload.parent_issue_id).to be_nil
  end

  it "does not link a PR follow-up run back to itself" do # @spec EAGER-QUEUE-009
    pull_request = create(:issue, :pull_request, project: project, github_number: 42, parent_issue_id: nil)
    create(:agent_run, :completed, project: project, issue: pull_request,
      goal: "create_pr", pull_request_number: 42)

    described_class.call(pull_request)

    expect(pull_request.reload.parent_issue_id).to be_nil
  end
end
