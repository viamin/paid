# frozen_string_literal: true

require "rails_helper"

# @spec AUTOMATION-PHASES-006
RSpec.describe Automation::ContinuationGrantLookup do
  let(:account) { create(:account) }
  let(:project) { create(:project, account:) }
  let(:issue) { create(:issue, project:) }

  def grant_for(work_item)
    create(:work_item_continuation_grant, project:, issue: work_item, start_phase: "coding", endpoint: "merge")
  end

  it "resolves a grant from the work item it was created for" do
    grant = grant_for(issue)

    expect(described_class.resolve(project:, phase: "coding", work_item: issue)).to contain_exactly(grant)
  end

  it "carries the grant across the implementation run for the same issue" do
    grant = grant_for(issue)
    run = create(:agent_run, project:, issue:, goal: "create_pr", trigger_type: "manual")

    expect(described_class.resolve(project:, phase: "coding", work_item: run)).to contain_exactly(grant)
  end

  it "carries the grant across the pull request opened for the issue" do
    grant = grant_for(issue)
    pull_request = create(:issue, :pull_request, project:, parent_issue: issue)

    expect(described_class.resolve(project:, phase: "merge", work_item: pull_request)).to contain_exactly(grant)
  end

  it "carries the grant from a pull-request-scoped run back to its source issue" do
    grant = grant_for(issue)
    pull_request = create(:issue, :pull_request, project:, parent_issue: issue)
    run = create(:agent_run, project:, issue: nil, goal: "review", trigger_type: "automatic",
      source_pull_request_number: pull_request.github_number)

    expect(described_class.resolve(project:, phase: "coding", work_item: run)).to contain_exactly(grant)
  end

  it "does not authorize an unrelated issue in the same project" do
    grant_for(issue)
    other_issue = create(:issue, project:)

    expect(described_class.resolve(project:, phase: "coding", work_item: other_issue)).to be_empty
  end

  it "does not inherit into an explicitly linked child issue" do
    grant_for(issue)
    child = create(:issue, project:, parent_issue: issue)

    expect(described_class.resolve(project:, phase: "coding", work_item: child)).to be_empty
  end

  it "does not inherit into an issue the work item merely depends on" do
    grant_for(issue)
    dependency = create(:issue, project:)

    expect(described_class.resolve(project:, phase: "coding", work_item: dependency)).to be_empty
  end

  it "returns nothing for work with no issue" do
    grant_for(issue)

    expect(described_class.resolve(project:, phase: "coding", work_item: nil)).to be_empty
  end

  describe "outstanding manual actions" do
    it "reports an unfinished operator-started run for the work chain" do
      create(:agent_run, project:, issue:, goal: "create_pr", trigger_type: "manual", status: "queued")

      expect(described_class.outstanding_manual_action?(project:, issue:)).to be(true)
    end

    it "reports no outstanding manual action once the run finished" do
      create(:agent_run, project:, issue:, goal: "create_pr", trigger_type: "manual", status: "completed")

      expect(described_class.outstanding_manual_action?(project:, issue:)).to be(false)
    end

    it "ignores automatic runs" do
      create(:agent_run, project:, issue:, goal: "create_pr", trigger_type: "automatic", status: "queued")

      expect(described_class.outstanding_manual_action?(project:, issue:)).to be(false)
    end
  end
end