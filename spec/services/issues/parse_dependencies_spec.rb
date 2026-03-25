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

    context "with cross-project references" do
      let(:account) { project.account }
      let(:other_project) { create(:project, account: account, owner: "viamin", repo: "agent-harness") }

      it "parses cross-project inline references" do
        dep = create(:issue, project: other_project, github_number: 9031)
        issue = create(:issue, project: project, body: "Depends on viamin/agent-harness#9031")

        described_class.call(issue: issue)

        expect(issue.dependencies).to contain_exactly(dep)
      end

      it "parses 'Blocked by' with cross-project references" do
        dep = create(:issue, project: other_project, github_number: 9042)
        issue = create(:issue, project: project, body: "Blocked by viamin/agent-harness#9042")

        described_class.call(issue: issue)

        expect(issue.dependencies).to contain_exactly(dep)
      end

      it "parses mixed local and cross-project references" do
        local_dep = create(:issue, project: project, github_number: 9010)
        cross_dep = create(:issue, project: other_project, github_number: 9031)
        issue = create(:issue, project: project,
                       body: "Depends on #9010, viamin/agent-harness#9031")

        described_class.call(issue: issue)

        expect(issue.dependencies).to contain_exactly(local_dep, cross_dep)
      end

      it "parses cross-project references in dependency sections" do
        dep = create(:issue, project: other_project, github_number: 9031)
        body = "## Dependencies\n- viamin/agent-harness#9031\n"
        issue = create(:issue, project: project, body: body)

        described_class.call(issue: issue)

        expect(issue.dependencies).to contain_exactly(dep)
      end

      it "creates external dependency when project is not synced" do
        issue = create(:issue, project: project,
                       body: "Depends on unknown-org/unknown-repo#9042")

        described_class.call(issue: issue)

        expect(issue.dependencies).to be_empty
        ext_dep = issue.issue_dependencies.find_by(depends_on_owner: "unknown-org")
        expect(ext_dep).to be_present
        expect(ext_dep.depends_on_repo).to eq("unknown-repo")
        expect(ext_dep.depends_on_number).to eq(9042)
      end

      it "creates external dependency when issue is not synced" do
        create(:project, account: account, owner: "viamin", repo: "other-repo")
        issue = create(:issue, project: project,
                       body: "Depends on viamin/other-repo#9999")

        described_class.call(issue: issue)

        ext_dep = issue.issue_dependencies.find_by(depends_on_owner: "viamin")
        expect(ext_dep).to be_present
        expect(ext_dep.depends_on_number).to eq(9999)
      end

      it "removes stale external dependencies when body changes" do
        issue = create(:issue, project: project,
                       body: "Depends on unknown-org/unknown-repo#9042")

        described_class.call(issue: issue)
        expect(issue.issue_dependencies.where.not(depends_on_owner: nil).count).to eq(1)

        issue.update!(body: "No dependencies")
        described_class.call(issue: issue)
        expect(issue.issue_dependencies.reload).to be_empty
      end

      it "is idempotent for external dependencies" do
        issue = create(:issue, project: project,
                       body: "Depends on unknown-org/unknown-repo#9042")

        described_class.call(issue: issue)
        expect { described_class.call(issue: issue) }.not_to change(IssueDependency, :count)
      end

      it "normalizes external dependency owner/repo to lowercase" do
        issue = create(:issue, project: project,
                       body: "Depends on Unknown-Org/Unknown-REPO#9042")

        described_class.call(issue: issue)

        ext_dep = issue.issue_dependencies.find_by(depends_on_owner: "unknown-org")
        expect(ext_dep).to be_present
        expect(ext_dep.depends_on_repo).to eq("unknown-repo")
      end

      it "deduplicates external deps with different casing" do
        issue = create(:issue, project: project,
                       body: "Depends on Unknown-Org/Repo#9042")

        described_class.call(issue: issue)
        expect(issue.issue_dependencies.count).to eq(1)

        issue.update!(body: "Depends on unknown-org/repo#9042")
        described_class.call(issue: issue)
        expect(issue.issue_dependencies.count).to eq(1)
      end

      it "ignores cross-project references with issue number zero" do
        issue = create(:issue, project: project,
                       body: "Depends on unknown-org/unknown-repo#0")

        described_class.call(issue: issue)

        expect(issue.issue_dependencies.reload).to be_empty
      end

      it "deduplicates when same issue is referenced as both local and cross-project" do
        dep = create(:issue, project: project, github_number: 9050)
        body = "Depends on #9050, #{project.owner}/#{project.repo}#9050"
        issue = create(:issue, project: project, body: body)

        described_class.call(issue: issue)

        expect(issue.dependencies).to contain_exactly(dep)
        expect(issue.issue_dependencies.count).to eq(1)
      end

      it "skips cross-project dependencies that would create a cycle" do
        cross_issue = create(:issue, project: other_project, github_number: 9001)
        local_issue = create(:issue, project: project, github_number: 9002)

        # cross_issue depends on local_issue
        create(:issue_dependency, issue: cross_issue, depends_on_issue: local_issue)

        # Trying to make local_issue depend on cross_issue would create a cycle
        local_issue.update!(body: "Depends on viamin/agent-harness#9001")
        described_class.call(issue: local_issue)

        expect(local_issue.dependencies.reload).to be_empty
      end
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
        "Depends on #9010. No longer depends on #9010"
      ])

      expect(issue.dependencies).to be_empty
    end

    it "removal in comment overrides body dependency" do
      create(:issue, project: project, github_number: 9010)
      issue = create(:issue, project: project, body: "Depends on #9010")

      described_class.call(issue: issue, comments: [ "No longer depends on #9010" ])

      expect(issue.dependencies).to be_empty
    end

    it "re-adds a dependency removed by an earlier comment" do
      dep = create(:issue, project: project, github_number: 9010)
      issue = create(:issue, project: project, body: "Depends on #9010")

      described_class.call(issue: issue, comments: [
        "No longer depends on #9010",
        "Depends on #9010"
      ])

      expect(issue.dependencies).to contain_exactly(dep)
    end

    it "does not affect body-only parsing when comments are empty" do
      dep = create(:issue, project: project, github_number: 9010)
      issue = create(:issue, project: project, body: "Depends on #9010")

      described_class.call(issue: issue, comments: [])

      expect(issue.dependencies).to contain_exactly(dep)
    end

    it "parses dependency sections in comments" do
      dep = create(:issue, project: project, github_number: 9101)
      issue = create(:issue, project: project, body: nil)

      described_class.call(issue: issue, comments: [ "## Dependencies\n- #9101\n" ])

      expect(issue.dependencies).to contain_exactly(dep)
    end

    context "with cross-repo removal in comments" do
      let(:account) { project.account }
      let(:other_project) { create(:project, account: account, owner: "viamin", repo: "agent-harness") }

      it "removes a cross-repo dependency via comment" do
        dep = create(:issue, project: other_project, github_number: 9031)
        issue = create(:issue, project: project, body: "Depends on viamin/agent-harness#9031")

        described_class.call(issue: issue)
        expect(issue.dependencies.reload).to contain_exactly(dep)

        described_class.call(issue: issue, comments: [ "No longer depends on viamin/agent-harness#9031" ])
        expect(issue.dependencies.reload).to be_empty
      end

      it "removes a cross-repo external dependency via comment" do
        issue = create(:issue, project: project,
                       body: "Depends on unknown-org/unknown-repo#9042")

        described_class.call(issue: issue)
        expect(issue.issue_dependencies.where.not(depends_on_owner: nil).count).to eq(1)

        described_class.call(issue: issue,
                             comments: [ "Remove dependency unknown-org/unknown-repo#9042" ])
        expect(issue.issue_dependencies.reload).to be_empty
      end

      it "cross-repo removal in same comment overrides addition" do
        create(:issue, project: other_project, github_number: 9031)
        issue = create(:issue, project: project, body: nil)

        described_class.call(issue: issue, comments: [
          "Depends on viamin/agent-harness#9031. No longer depends on viamin/agent-harness#9031"
        ])

        expect(issue.dependencies).to be_empty
      end

      it "re-adds a cross-repo dependency removed by an earlier comment" do
        dep = create(:issue, project: other_project, github_number: 9031)
        issue = create(:issue, project: project,
                       body: "Depends on viamin/agent-harness#9031")

        described_class.call(issue: issue, comments: [
          "No longer depends on viamin/agent-harness#9031",
          "Depends on viamin/agent-harness#9031"
        ])

        expect(issue.dependencies).to contain_exactly(dep)
      end
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
