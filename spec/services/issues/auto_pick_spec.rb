# frozen_string_literal: true

require "rails_helper"

RSpec.describe Issues::AutoPick do
  let(:project) { create(:project, auto_pick_enabled: true) }

  describe "#call" do
    it "selects the next unblocked open issue and creates a queued agent run" do
      issue = create(:issue, project: project, github_state: "open")

      result = described_class.new(project).call

      expect(result).to be_a(AgentRun)
      expect(result.issue).to eq(issue)
      expect(result.project).to eq(project)
      expect(result.status).to eq("queued")
      expect(result.trigger_type).to eq("automatic")
      expect(result.agent_type).to eq("claude_code")
    end

    it "returns nil when auto_pick is disabled on the project" do
      project.update!(auto_pick_enabled: false)
      create(:issue, project: project, github_state: "open")

      result = described_class.new(project).call

      expect(result).to be_nil
    end

    it "skips issues labeled planning" do
      create(:issue, project: project, labels: [ "planning" ])
      eligible = create(:issue, project: project, labels: [])

      result = described_class.new(project).call

      expect(result.issue).to eq(eligible)
    end

    it "skips issues labeled research" do
      create(:issue, project: project, labels: [ "research" ])

      result = described_class.new(project).call

      expect(result).to be_nil
    end

    it "skips issues labeled waiting" do
      create(:issue, project: project, labels: [ "waiting" ])

      result = described_class.new(project).call

      expect(result).to be_nil
    end

    it "skips issues with mixed labels including excluded ones" do
      create(:issue, project: project, labels: [ "bug", "planning", "urgent" ])
      eligible = create(:issue, project: project, labels: [ "bug", "urgent" ])

      result = described_class.new(project).call

      expect(result.issue).to eq(eligible)
    end

    it "skips issues with open dependencies (blocked issues)" do
      blocking = create(:issue, project: project, github_state: "open")
      blocked = create(:issue, project: project, github_state: "open")
      create(:issue_dependency, issue: blocked, depends_on_issue: blocking)

      result = described_class.new(project).call

      expect(result.issue).to eq(blocking)
    end

    it "includes issues whose dependencies are all closed" do
      closed_dep = create(:issue, project: project, github_state: "closed")
      unblocked = create(:issue, project: project, github_state: "open")
      create(:issue_dependency, issue: unblocked, depends_on_issue: closed_dep)

      result = described_class.new(project).call

      expect(result.issue).to eq(unblocked)
    end

    it "skips issues with in_progress paid_state" do
      create(:issue, :in_progress, project: project)

      result = described_class.new(project).call

      expect(result).to be_nil
    end

    it "skips issues with completed paid_state" do
      create(:issue, :completed, project: project)

      result = described_class.new(project).call

      expect(result).to be_nil
    end

    it "includes issues with failed paid_state" do
      issue = create(:issue, :failed, project: project)

      result = described_class.new(project).call

      expect(result.issue).to eq(issue)
    end

    it "skips closed issues" do
      create(:issue, project: project, github_state: "closed")

      result = described_class.new(project).call

      expect(result).to be_nil
    end

    it "skips pull requests" do
      create(:issue, :pull_request, project: project)

      result = described_class.new(project).call

      expect(result).to be_nil
    end

    it "skips issues that already have an active agent run" do
      issue_with_run = create(:issue, project: project)
      create(:agent_run, :queued, project: project, issue: issue_with_run)
      eligible = create(:issue, project: project)

      result = described_class.new(project).call

      expect(result.issue).to eq(eligible)
    end

    it "picks the issue with the lowest github_number first" do
      later = create(:issue, project: project, github_number: 200)
      earlier = create(:issue, project: project, github_number: 100)

      result = described_class.new(project).call

      expect(result.issue).to eq(earlier)
      expect(later.reload.agent_runs).to be_empty
    end

    it "returns nil when no eligible issues exist" do
      result = described_class.new(project).call

      expect(result).to be_nil
    end

    it "returns nil gracefully when all issues are blocked" do
      a = create(:issue, project: project, github_state: "open")
      b = create(:issue, project: project, github_state: "open")
      create(:issue_dependency, issue: a, depends_on_issue: b)
      create(:issue_dependency, issue: b, depends_on_issue: a)

      result = described_class.new(project).call

      expect(result).to be_nil
    end

    it "logs the auto-pick event" do
      issue = create(:issue, project: project)

      allow(Rails.logger).to receive(:info)

      described_class.new(project).call

      expect(Rails.logger).to have_received(:info).with(
        hash_including(message: "auto_pick.issue_selected", issue_id: issue.id)
      )
    end
  end
end
