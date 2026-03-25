# frozen_string_literal: true

require "rails_helper"

RSpec.describe Issues::ParseDependencies do
  let(:project) { create(:project) }

  # Use high github_numbers (9000+) for dependency targets to avoid collisions
  # with FactoryBot's global github_number sequence (which starts at 1 and
  # increments across all tests in the suite).

  describe ".call" do
    it "parses dependencies from a Dependencies section" do
      dep1 = create(:issue, project: project, github_number: 9101)
      dep2 = create(:issue, project: project, github_number: 9102)
      issue = create(:issue, project: project, body: "## Dependencies\n- #9101\n- #9102\n")

      described_class.call(issue: issue)

      expect(issue.dependencies).to contain_exactly(dep1, dep2)
    end

    it "parses 'Depends on' inline references" do
      dep = create(:issue, project: project, github_number: 9050)
      issue = create(:issue, project: project, body: "This issue depends on #9050.")

      described_class.call(issue: issue)

      expect(issue.dependencies).to contain_exactly(dep)
    end

    it "parses 'Depends on:' with colon" do
      dep = create(:issue, project: project, github_number: 9010)
      issue = create(:issue, project: project, body: "Depends on: #9010")

      described_class.call(issue: issue)

      expect(issue.dependencies).to contain_exactly(dep)
    end

    it "parses 'Blocked by' references" do
      dep = create(:issue, project: project, github_number: 9042)
      issue = create(:issue, project: project, body: "Blocked by #9042")

      described_class.call(issue: issue)

      expect(issue.dependencies).to contain_exactly(dep)
    end

    it "parses multiple comma-separated references" do
      dep1 = create(:issue, project: project, github_number: 9001)
      dep2 = create(:issue, project: project, github_number: 9002)
      dep3 = create(:issue, project: project, github_number: 9003)
      issue = create(:issue, project: project, body: "Depends on #9001, #9002, #9003")

      described_class.call(issue: issue)

      expect(issue.dependencies).to contain_exactly(dep1, dep2, dep3)
    end

    it "ignores references to non-existent issues" do
      issue = create(:issue, project: project, body: "Depends on #9999")

      described_class.call(issue: issue)

      expect(issue.dependencies).to be_empty
    end

    it "ignores self-references" do
      issue = create(:issue, project: project, github_number: 9005, body: "Depends on #9005")

      described_class.call(issue: issue)

      expect(issue.dependencies).to be_empty
    end

    it "ignores references to pull requests" do
      create(:issue, :pull_request, project: project, github_number: 9007)
      issue = create(:issue, project: project, body: "Depends on #9007")

      described_class.call(issue: issue)

      expect(issue.dependencies).to be_empty
    end

    it "does nothing when body is blank and no existing dependencies" do
      issue = create(:issue, project: project, body: nil)

      expect { described_class.call(issue: issue) }.not_to change(IssueDependency, :count)
    end

    it "removes all dependencies when body becomes blank" do
      dep = create(:issue, project: project, github_number: 9010)
      issue = create(:issue, project: project, body: "Depends on #9010")

      described_class.call(issue: issue)
      expect(issue.dependencies.reload).to contain_exactly(dep)

      issue.update!(body: nil)
      described_class.call(issue: issue)
      expect(issue.dependencies.reload).to be_empty
    end

    it "removes all dependencies when dependency section is cleared" do
      dep = create(:issue, project: project, github_number: 9010)
      issue = create(:issue, project: project, body: "Depends on #9010")

      described_class.call(issue: issue)
      expect(issue.dependencies.reload).to contain_exactly(dep)

      issue.update!(body: "No dependencies anymore")
      described_class.call(issue: issue)
      expect(issue.dependencies.reload).to be_empty
    end

    it "removes stale dependencies when body changes" do
      dep1 = create(:issue, project: project, github_number: 9010)
      dep2 = create(:issue, project: project, github_number: 9020)
      issue = create(:issue, project: project, body: "Depends on #9010, #9020")

      described_class.call(issue: issue)
      expect(issue.dependencies.reload).to contain_exactly(dep1, dep2)

      issue.update!(body: "Depends on #9010")
      described_class.call(issue: issue)
      expect(issue.dependencies.reload).to contain_exactly(dep1)
    end

    it "is idempotent" do
      create(:issue, project: project, github_number: 9010)
      issue = create(:issue, project: project, body: "Depends on #9010")

      described_class.call(issue: issue)
      expect { described_class.call(issue: issue) }.not_to change(IssueDependency, :count)
    end

    it "skips dependencies that would create a cycle" do
      issue_a = create(:issue, project: project, github_number: 9001)
      issue_b = create(:issue, project: project, github_number: 9002,
                       body: "Depends on #9001")

      described_class.call(issue: issue_b)
      expect(issue_b.dependencies).to contain_exactly(issue_a)

      issue_a.update!(body: "Depends on #9002")
      described_class.call(issue: issue_a)
      expect(issue_a.dependencies.reload).to be_empty
    end

    it "parses dependencies from a section followed by another heading" do
      dep = create(:issue, project: project, github_number: 9101)
      create(:issue, project: project, github_number: 9999)
      body = "## Dependencies\n- #9101\n\n## Notes\nSome notes mentioning #9999\n"
      issue = create(:issue, project: project, body: body)

      described_class.call(issue: issue)

      expect(issue.dependencies).to contain_exactly(dep)
    end

    it "parses checklist items with issue references" do
      dep = create(:issue, project: project, github_number: 9015)
      body = "## Dependencies\n- [ ] #9015 complete the setup\n"
      issue = create(:issue, project: project, body: body)

      described_class.call(issue: issue)

      expect(issue.dependencies).to contain_exactly(dep)
    end
  end

  describe "comment parsing" do
    it "parses dependencies from comments" do
      dep = create(:issue, project: project, github_number: 9050)
      issue = create(:issue, project: project, body: nil)

      described_class.call(issue: issue, comments: [ "Depends on #9050" ])

      expect(issue.dependencies).to contain_exactly(dep)
    end

    it "merges comment dependencies with body dependencies" do
      dep1 = create(:issue, project: project, github_number: 9010)
      dep2 = create(:issue, project: project, github_number: 9020)
      issue = create(:issue, project: project, body: "Depends on #9010")

      described_class.call(issue: issue, comments: [ "Blocked by #9020" ])

      expect(issue.dependencies).to contain_exactly(dep1, dep2)
    end

    it "parses 'Blocked by' in comments" do
      dep = create(:issue, project: project, github_number: 9042)
      issue = create(:issue, project: project, body: nil)

      described_class.call(issue: issue, comments: [ "Blocked by #9042" ])

      expect(issue.dependencies).to contain_exactly(dep)
    end

    it "handles multiple comments with dependencies" do
      dep1 = create(:issue, project: project, github_number: 9010)
      dep2 = create(:issue, project: project, github_number: 9020)
      issue = create(:issue, project: project, body: nil)

      described_class.call(issue: issue, comments: [
        "Depends on #9010",
        "Also blocked by #9020"
      ])

      expect(issue.dependencies).to contain_exactly(dep1, dep2)
    end

    it "ignores blank comments" do
      issue = create(:issue, project: project, body: nil)

      expect { described_class.call(issue: issue, comments: [ nil, "", "  " ]) }
        .not_to change(IssueDependency, :count)
    end

    it "removes dependencies via 'no longer depends on'" do
      dep1 = create(:issue, project: project, github_number: 9010)
      dep2 = create(:issue, project: project, github_number: 9020)
      issue = create(:issue, project: project, body: "Depends on #9010, #9020")

      described_class.call(issue: issue)
      expect(issue.dependencies.reload).to contain_exactly(dep1, dep2)

      described_class.call(issue: issue, comments: [ "No longer depends on #9020" ])
      expect(issue.dependencies.reload).to contain_exactly(dep1)
    end

    it "removes dependencies via 'no longer blocked by'" do
      dep = create(:issue, project: project, github_number: 9010)
      issue = create(:issue, project: project, body: "Blocked by #9010")

      described_class.call(issue: issue)
      expect(issue.dependencies.reload).to contain_exactly(dep)

      described_class.call(issue: issue, comments: [ "No longer blocked by #9010" ])
      expect(issue.dependencies.reload).to be_empty
    end

    it "removes dependencies via 'unblocked by'" do
      dep = create(:issue, project: project, github_number: 9010)
      issue = create(:issue, project: project, body: "Blocked by #9010")

      described_class.call(issue: issue)
      expect(issue.dependencies.reload).to contain_exactly(dep)

      described_class.call(issue: issue, comments: [ "Unblocked by #9010" ])
      expect(issue.dependencies.reload).to be_empty
    end

    it "removes dependencies via 'remove dependency'" do
      dep = create(:issue, project: project, github_number: 9010)
      issue = create(:issue, project: project, body: "Depends on #9010")

      described_class.call(issue: issue)
      expect(issue.dependencies.reload).to contain_exactly(dep)

      described_class.call(issue: issue, comments: [ "Remove dependency #9010" ])
      expect(issue.dependencies.reload).to be_empty
    end

    it "removal in comment overrides addition in same comment" do
      create(:issue, project: project, github_number: 9010)
      issue = create(:issue, project: project, body: nil)

      described_class.call(issue: issue, comments: [
        "Depends on #9010",
        "No longer depends on #9010"
      ])

      expect(issue.dependencies).to be_empty
    end

    it "removal in comment overrides body dependency" do
      create(:issue, project: project, github_number: 9010)
      issue = create(:issue, project: project, body: "Depends on #9010")

      described_class.call(issue: issue, comments: [ "No longer depends on #9010" ])

      expect(issue.dependencies).to be_empty
    end

    it "does not affect body-only parsing when comments are empty" do
      dep = create(:issue, project: project, github_number: 9010)
      issue = create(:issue, project: project, body: "Depends on #9010")

      described_class.call(issue: issue, comments: [])

      expect(issue.dependencies).to contain_exactly(dep)
    end

    it "is idempotent with comments" do
      create(:issue, project: project, github_number: 9010)
      issue = create(:issue, project: project, body: nil)

      described_class.call(issue: issue, comments: [ "Depends on #9010" ])
      expect { described_class.call(issue: issue, comments: [ "Depends on #9010" ]) }
        .not_to change(IssueDependency, :count)
    end
  end
end
