# frozen_string_literal: true

require "rails_helper"

RSpec.describe ConventionalCommitTitle do
  describe ".normalize" do
    it "returns a normalized conventional commit title" do
      expect(described_class.normalize("Feat(quality): Pause low-quality automation"))
        .to eq("feat(quality): Pause low-quality automation")
    end

    it "supports breaking-change markers" do
      expect(described_class.normalize("feat!: Replace automation policy"))
        .to eq("feat!: Replace automation policy")
    end

    it "strips surrounding whitespace" do
      expect(described_class.normalize("  fix(agent-runs): Resume stalled runs  "))
        .to eq("fix(agent-runs): Resume stalled runs")
    end

    it "rejects titles that only contain a conventional commit inside non-conventional text" do
      expect(described_class.normalize("Fix #714: feat(quality): Pause low-quality automation")).to be_nil
    end

    it "rejects ordinary issue titles" do
      expect(described_class.normalize("Add queue monitoring dashboard")).to be_nil
    end
  end

  describe ".for_issue" do
    let(:project) { create(:project) }

    it "reuses conventional issue titles as-is" do
      issue = create(:issue, project: project, title: "Feat(quality): Pause low-quality automation")

      expect(described_class.for_issue(issue)).to eq("feat(quality): Pause low-quality automation")
    end

    it "infers feature commits from plain-English feature titles" do
      issue = create(:issue, project: project, title: "Add queue monitoring dashboard")

      expect(described_class.for_issue(issue)).to eq("feat: Add queue monitoring dashboard")
    end

    it "infers fix commits from plain-English fix titles" do
      issue = create(:issue, project: project, title: "Resolve stalled worker retries")

      expect(described_class.for_issue(issue)).to eq("fix: Resolve stalled worker retries")
    end

    it "prefers an explicit fix prefix over later category nouns" do
      issue = create(:issue, project: project, title: "Fix Docker image auth failure")

      expect(described_class.for_issue(issue)).to eq("fix: Fix Docker image auth failure")
    end

    it "uses fix labels as a strong hint" do
      issue = create(:issue, project: project, title: "Worker pool tuning", labels: [ "bug" ])

      expect(described_class.for_issue(issue)).to eq("fix: Worker pool tuning")
    end

    it "falls back to feat for ambiguous issue titles" do
      issue = create(:issue, project: project, title: "Worker pool tuning")

      expect(described_class.for_issue(issue)).to eq("feat: Worker pool tuning")
    end

    it "uses the provided fallback type when no heuristic matches" do
      issue = create(:issue, project: project, title: "Worker pool tuning")

      expect(described_class.for_issue(issue, fallback_type: "chore")).to eq("chore: Worker pool tuning")
    end

    it "uses plain titles when the project overrides commit style away from conventional commits" do
      create(:project_convention_override,
        project: project,
        key: "commit_style",
        value: { "type" => "plain", "fallback_subject" => "Apply Paid changes" })
      issue = create(:issue, project: project, title: "Worker pool tuning")

      expect(described_class.for_issue(issue, project: project)).to eq("Worker pool tuning")
    end

    it "uses the plain fallback subject when the project disables conventional commits and no issue title is present" do
      create(:project_convention_override,
        project: project,
        key: "commit_style",
        value: { "type" => "plain", "fallback_subject" => "Apply Paid changes" })

      expect(described_class.for_issue(nil, project: project)).to eq("Apply Paid changes")
    end
  end
end
