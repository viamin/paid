# frozen_string_literal: true

require "rails_helper"

RSpec.describe Automation::Strategies::AutoPick::DefaultCandidateSource do
  let(:project) { create(:project, auto_pick_enabled: true) }

  describe ".next_candidate" do
    it "returns the top-ranked eligible issue for the project" do
      issue = create(:issue, project: project, github_state: "open")

      expect(described_class.next_candidate(project)).to eq(issue)
    end

    it "returns nil when the project has no eligible candidates" do
      create(:issue, project: project, labels: [ "planning" ])

      expect(described_class.next_candidate(project)).to be_nil
    end

    it "prefers higher-priority issues over lower-priority ones" do
      _p3 = create(:issue, project: project, github_number: 1, labels: [ "P3" ])
      p1 = create(:issue, project: project, github_number: 2, labels: [ "P1" ])

      expect(described_class.next_candidate(project)).to eq(p1)
    end
  end

  describe ".eligible_scope" do
    it "returns a scope limited to eligible issues" do
      eligible = create(:issue, project: project)
      create(:issue, project: project, labels: [ "planning" ])

      scope = described_class.eligible_scope(project)

      expect(scope.pluck(:id)).to contain_exactly(eligible.id)
    end

    it "includes completed issues with no PR-producing run (infrastructure failure recovery)" do
      issue = create(:issue, project: project, paid_state: "completed")
      create(:agent_run, :completed, project: project, issue: issue, pull_request_number: nil)

      scope = described_class.eligible_scope(project)

      expect(scope.pluck(:id)).to contain_exactly(issue.id)
    end

    it "excludes completed issues that had a PR-producing run" do
      issue = create(:issue, project: project, paid_state: "completed")
      create(:agent_run, :completed, project: project, issue: issue, pull_request_number: 42)

      scope = described_class.eligible_scope(project)

      expect(scope.pluck(:id)).to be_empty
    end

    it "includes completed issues even when other PR-producing runs have NULL issue_id" do
      issue = create(:issue, project: project, paid_state: "completed")
      create(:agent_run, :completed, project: project, issue: issue, pull_request_number: nil)
      create(:agent_run, :completed, project: project, issue: nil, pull_request_number: 99,
        custom_prompt: "manual PR run")

      scope = described_class.eligible_scope(project)

      expect(scope.pluck(:id)).to contain_exactly(issue.id)
    end
  end

  describe ".eligible_issue_ids" do
    it "returns the subset of displayed issues that are eligible" do
      eligible = create(:issue, project: project)
      planning = create(:issue, project: project, labels: [ "planning" ])

      result = described_class.eligible_issue_ids([ eligible, planning ])

      expect(result).to be_a(Set)
      expect(result).to include(eligible.id)
      expect(result).not_to include(planning.id)
    end

    it "returns an empty set when given an empty collection" do
      expect(described_class.eligible_issue_ids([])).to eq(Set.new)
    end
  end

  describe "interface compliance" do
    it "responds to every method declared by the CandidateSource interface" do
      %i[eligible_issue_ids eligible_scope next_candidate].each do |method_name|
        expect(described_class).to respond_to(method_name)
      end
    end
  end
end
