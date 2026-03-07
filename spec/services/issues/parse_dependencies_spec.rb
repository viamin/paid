# frozen_string_literal: true

require "rails_helper"

RSpec.describe Issues::ParseDependencies do
  let(:project) { create(:project) }

  describe ".call" do
    it "parses dependencies from a Dependencies section" do
      dep1 = create(:issue, project: project, github_number: 101)
      dep2 = create(:issue, project: project, github_number: 102)
      issue = create(:issue, project: project, body: "## Dependencies\n- #101\n- #102\n")

      described_class.call(issue: issue)

      expect(issue.dependencies).to contain_exactly(dep1, dep2)
    end

    it "parses 'Depends on' inline references" do
      dep = create(:issue, project: project, github_number: 50)
      issue = create(:issue, project: project, body: "This issue depends on #50.")

      described_class.call(issue: issue)

      expect(issue.dependencies).to contain_exactly(dep)
    end

    it "parses 'Depends on:' with colon" do
      dep = create(:issue, project: project, github_number: 10)
      issue = create(:issue, project: project, body: "Depends on: #10")

      described_class.call(issue: issue)

      expect(issue.dependencies).to contain_exactly(dep)
    end

    it "parses 'Blocked by' references" do
      dep = create(:issue, project: project, github_number: 42)
      issue = create(:issue, project: project, body: "Blocked by #42")

      described_class.call(issue: issue)

      expect(issue.dependencies).to contain_exactly(dep)
    end

    it "parses multiple comma-separated references" do
      dep1 = create(:issue, project: project, github_number: 1)
      dep2 = create(:issue, project: project, github_number: 2)
      dep3 = create(:issue, project: project, github_number: 3)
      issue = create(:issue, project: project, body: "Depends on #1, #2, #3")

      described_class.call(issue: issue)

      expect(issue.dependencies).to contain_exactly(dep1, dep2, dep3)
    end

    it "ignores references to non-existent issues" do
      issue = create(:issue, project: project, body: "Depends on #999")

      described_class.call(issue: issue)

      expect(issue.dependencies).to be_empty
    end

    it "ignores self-references" do
      issue = create(:issue, project: project, github_number: 5, body: "Depends on #5")

      described_class.call(issue: issue)

      expect(issue.dependencies).to be_empty
    end

    it "ignores references to pull requests" do
      create(:issue, :pull_request, project: project, github_number: 7)
      issue = create(:issue, project: project, body: "Depends on #7")

      described_class.call(issue: issue)

      expect(issue.dependencies).to be_empty
    end

    it "does nothing when body is blank and no existing dependencies" do
      issue = create(:issue, project: project, body: nil)

      expect { described_class.call(issue: issue) }.not_to change(IssueDependency, :count)
    end

    it "removes all dependencies when body becomes blank" do
      dep = create(:issue, project: project, github_number: 10)
      issue = create(:issue, project: project, body: "Depends on #10")

      described_class.call(issue: issue)
      expect(issue.dependencies.reload).to contain_exactly(dep)

      issue.update!(body: nil)
      described_class.call(issue: issue)
      expect(issue.dependencies.reload).to be_empty
    end

    it "removes all dependencies when dependency section is cleared" do
      dep = create(:issue, project: project, github_number: 10)
      issue = create(:issue, project: project, body: "Depends on #10")

      described_class.call(issue: issue)
      expect(issue.dependencies.reload).to contain_exactly(dep)

      issue.update!(body: "No dependencies anymore")
      described_class.call(issue: issue)
      expect(issue.dependencies.reload).to be_empty
    end

    it "removes stale dependencies when body changes" do
      dep1 = create(:issue, project: project, github_number: 10)
      dep2 = create(:issue, project: project, github_number: 20)
      issue = create(:issue, project: project, body: "Depends on #10, #20")

      described_class.call(issue: issue)
      expect(issue.dependencies.reload).to contain_exactly(dep1, dep2)

      issue.update!(body: "Depends on #10")
      described_class.call(issue: issue)
      expect(issue.dependencies.reload).to contain_exactly(dep1)
    end

    it "is idempotent" do
      create(:issue, project: project, github_number: 10)
      issue = create(:issue, project: project, body: "Depends on #10")

      described_class.call(issue: issue)
      expect { described_class.call(issue: issue) }.not_to change(IssueDependency, :count)
    end

    it "skips dependencies that would create a cycle" do
      issue_a = create(:issue, project: project, github_number: 1)
      issue_b = create(:issue, project: project, github_number: 2,
                       body: "Depends on #1")

      described_class.call(issue: issue_b)
      expect(issue_b.dependencies).to contain_exactly(issue_a)

      issue_a.update!(body: "Depends on #2")
      described_class.call(issue: issue_a)
      expect(issue_a.dependencies.reload).to be_empty
    end

    it "parses dependencies from a section followed by another heading" do
      dep = create(:issue, project: project, github_number: 101)
      create(:issue, project: project, github_number: 999)
      body = "## Dependencies\n- #101\n\n## Notes\nSome notes mentioning #999\n"
      issue = create(:issue, project: project, body: body)

      described_class.call(issue: issue)

      expect(issue.dependencies).to contain_exactly(dep)
    end

    it "parses checklist items with issue references" do
      dep = create(:issue, project: project, github_number: 15)
      body = "## Dependencies\n- [ ] #15 complete the setup\n"
      issue = create(:issue, project: project, body: body)

      described_class.call(issue: issue)

      expect(issue.dependencies).to contain_exactly(dep)
    end
  end
end
