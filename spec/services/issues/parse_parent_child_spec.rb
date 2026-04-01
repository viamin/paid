# frozen_string_literal: true

require "rails_helper"

RSpec.describe Issues::ParseParentChild do
  let(:project) { create(:project) }

  # Use high github_numbers (8000+) to avoid collisions with FactoryBot's
  # global github_number sequence.

  describe ".call" do
    describe "parent listing children (body sections)" do
      it "parses children from a Child Issues section" do
        child1 = create(:issue, project: project, github_number: 8001)
        child2 = create(:issue, project: project, github_number: 8002)
        parent = create(:issue, project: project, body: "## Child Issues\n- [ ] #8001\n- [ ] #8002\n")

        described_class.call(issue: parent)

        expect(child1.reload.parent_issue_id).to eq(parent.id)
        expect(child2.reload.parent_issue_id).to eq(parent.id)
      end

      it "parses children from a Sub-issues section" do
        child = create(:issue, project: project, github_number: 8010)
        parent = create(:issue, project: project, body: "## Sub-issues\n- #8010\n")

        described_class.call(issue: parent)

        expect(child.reload.parent_issue_id).to eq(parent.id)
      end

      it "parses children from a Subtasks section" do
        child = create(:issue, project: project, github_number: 8020)
        parent = create(:issue, project: project, body: "## Subtasks\n- [ ] #8020\n")

        described_class.call(issue: parent)

        expect(child.reload.parent_issue_id).to eq(parent.id)
      end

      it "parses children from a Sub Tasks section" do
        child = create(:issue, project: project, github_number: 8021)
        parent = create(:issue, project: project, body: "## Sub Tasks\n- [ ] #8021\n")

        described_class.call(issue: parent)

        expect(child.reload.parent_issue_id).to eq(parent.id)
      end

      it "handles sections with sub-headings" do
        child1 = create(:issue, project: project, github_number: 8030)
        child2 = create(:issue, project: project, github_number: 8031)
        body = <<~BODY
          ## Child Issues

          ### Category A
          - [ ] #8030

          ### Category B
          - [ ] #8031
        BODY
        parent = create(:issue, project: project, body: body)

        described_class.call(issue: parent)

        expect(child1.reload.parent_issue_id).to eq(parent.id)
        expect(child2.reload.parent_issue_id).to eq(parent.id)
      end

      it "stops at the next heading of same level" do
        child = create(:issue, project: project, github_number: 8040)
        other = create(:issue, project: project, github_number: 8041)
        body = <<~BODY
          ## Child Issues
          - [ ] #8040

          ## Other Section
          References #8041 but not a child
        BODY
        parent = create(:issue, project: project, body: body)

        described_class.call(issue: parent)

        expect(child.reload.parent_issue_id).to eq(parent.id)
        expect(other.reload.parent_issue_id).to be_nil
      end

      it "works with any heading level" do
        child = create(:issue, project: project, github_number: 8050)
        parent = create(:issue, project: project, body: "### Child Issues\n- #8050\n")

        described_class.call(issue: parent)

        expect(child.reload.parent_issue_id).to eq(parent.id)
      end

      it "includes checked items" do
        child = create(:issue, project: project, github_number: 8055)
        parent = create(:issue, project: project, body: "## Child Issues\n- [x] #8055\n")

        described_class.call(issue: parent)

        expect(child.reload.parent_issue_id).to eq(parent.id)
      end

      it "parses multiple matching sections" do
        child1 = create(:issue, project: project, github_number: 8056)
        child2 = create(:issue, project: project, github_number: 8057)
        body = <<~BODY
          ## Child Issues
          - [ ] #8056

          ## Subtasks
          - [ ] #8057
        BODY
        parent = create(:issue, project: project, body: body)

        described_class.call(issue: parent)

        expect(child1.reload.parent_issue_id).to eq(parent.id)
        expect(child2.reload.parent_issue_id).to eq(parent.id)
      end

      it "last writer wins when two parents claim the same child" do
        child = create(:issue, project: project, github_number: 8058)
        parent1 = create(:issue, project: project, body: "## Child Issues\n- #8058\n")
        parent2 = create(:issue, project: project, body: "## Child Issues\n- #8058\n")

        described_class.call(issue: parent1)
        expect(child.reload.parent_issue_id).to eq(parent1.id)

        described_class.call(issue: parent2)
        expect(child.reload.parent_issue_id).to eq(parent2.id)
      end

      it "ignores self-references" do
        parent = create(:issue, project: project, github_number: 8060, body: "## Child Issues\n- #8060\n")

        described_class.call(issue: parent)

        expect(parent.reload.parent_issue_id).to be_nil
      end

      it "ignores references to non-existent issues" do
        parent = create(:issue, project: project, body: "## Child Issues\n- #9999\n")

        expect { described_class.call(issue: parent) }.not_to raise_error
      end

      it "does not set parent on pull requests" do
        pr = create(:issue, :pull_request, project: project, github_number: 8070)
        parent = create(:issue, project: project, body: "## Child Issues\n- #8070\n")

        described_class.call(issue: parent)

        expect(pr.reload.parent_issue_id).to be_nil
      end

      it "clears stale children removed from the list" do
        child1 = create(:issue, project: project, github_number: 8080)
        child2 = create(:issue, project: project, github_number: 8081)
        parent = create(:issue, project: project, body: "## Child Issues\n- #8080\n- #8081\n")

        described_class.call(issue: parent)
        expect(child1.reload.parent_issue_id).to eq(parent.id)
        expect(child2.reload.parent_issue_id).to eq(parent.id)

        # Remove child2 from the list
        parent.update!(body: "## Child Issues\n- #8080\n")
        described_class.call(issue: parent)

        expect(child1.reload.parent_issue_id).to eq(parent.id)
        expect(child2.reload.parent_issue_id).to be_nil
      end

      it "preserves children when section is removed to avoid clearing child-declares-parent links" do
        child = create(:issue, project: project, github_number: 8090)
        parent = create(:issue, project: project, body: "## Child Issues\n- #8090\n")

        described_class.call(issue: parent)
        expect(child.reload.parent_issue_id).to eq(parent.id)

        # Removing the section entirely yields an empty child_numbers set.
        # We intentionally do NOT clear children here because we can't
        # distinguish parent-listed children from child-declared parents.
        parent.update!(body: "No more child issues here.")
        described_class.call(issue: parent)

        expect(child.reload.parent_issue_id).to eq(parent.id)
      end

      it "does not clear PR parent_issue_id when clearing stale children" do
        pr = create(:issue, :pull_request, project: project, github_number: 8095,
                    parent_issue_id: nil)
        parent = create(:issue, project: project, body: "## Child Issues\n- #8095\n")

        # Manually set PR parent (simulating future PR linking)
        pr.update_columns(parent_issue_id: parent.id)

        # Parse with empty child list — should not clear the PR's parent
        parent.update!(body: "No children anymore.")
        described_class.call(issue: parent)

        expect(pr.reload.parent_issue_id).to eq(parent.id)
      end
    end

    describe "child declaring parent (inline)" do
      it "parses 'Part of #NNN'" do
        parent = create(:issue, project: project, github_number: 8100)
        child = create(:issue, project: project, body: "Part of #8100")

        described_class.call(issue: child)

        expect(child.reload.parent_issue_id).to eq(parent.id)
      end

      it "parses 'Child of #NNN'" do
        parent = create(:issue, project: project, github_number: 8110)
        child = create(:issue, project: project, body: "Child of #8110")

        described_class.call(issue: child)

        expect(child.reload.parent_issue_id).to eq(parent.id)
      end

      it "parses 'Sub-issue of #NNN'" do
        parent = create(:issue, project: project, github_number: 8120)
        child = create(:issue, project: project, body: "Sub-issue of #8120")

        described_class.call(issue: child)

        expect(child.reload.parent_issue_id).to eq(parent.id)
      end

      it "parses 'Subtask of #NNN'" do
        parent = create(:issue, project: project, github_number: 8130)
        child = create(:issue, project: project, body: "Subtask of #8130")

        described_class.call(issue: child)

        expect(child.reload.parent_issue_id).to eq(parent.id)
      end

      it "ignores self-references" do
        issue = create(:issue, project: project, github_number: 8140, body: "Part of #8140")

        described_class.call(issue: issue)

        expect(issue.reload.parent_issue_id).to be_nil
      end

      it "ignores references to non-existent issues" do
        child = create(:issue, project: project, body: "Part of #9998")

        described_class.call(issue: child)

        expect(child.reload.parent_issue_id).to be_nil
      end

      it "ignores references to pull requests" do
        create(:issue, :pull_request, project: project, github_number: 8150)
        child = create(:issue, project: project, body: "Part of #8150")

        described_class.call(issue: child)

        expect(child.reload.parent_issue_id).to be_nil
      end
    end

    describe "comments" do
      it "adds children from comment child sections" do
        child = create(:issue, project: project, github_number: 8200)
        parent = create(:issue, project: project, body: "Some body text")

        described_class.call(issue: parent, comments: [ "## Child Issues\n- #8200" ])

        expect(child.reload.parent_issue_id).to eq(parent.id)
      end

      it "removes parent via comment removal pattern" do
        create(:issue, project: project, github_number: 8210)
        child = create(:issue, project: project, body: "Part of #8210")

        described_class.call(
          issue: child,
          comments: [ "No longer part of #8210" ]
        )

        expect(child.reload.parent_issue_id).to be_nil
      end

      it "re-adds parent after removal via later comment" do
        parent = create(:issue, project: project, github_number: 8220)
        child = create(:issue, project: project, body: "Part of #8220")

        described_class.call(
          issue: child,
          comments: [
            "No longer part of #8220",
            "Part of #8220"
          ]
        )

        expect(child.reload.parent_issue_id).to eq(parent.id)
      end

      it "does not overwrite an unrelated parent when removing a different one" do
        parent_a = create(:issue, project: project, github_number: 8211)
        create(:issue, project: project, github_number: 8212)
        child = create(:issue, project: project, body: "Part of #8211")

        # "No longer part of #8212" should not affect the existing parent (#8211)
        described_class.call(
          issue: child,
          comments: [ "No longer part of #8212" ]
        )

        expect(child.reload.parent_issue_id).to eq(parent_a.id)
      end

      it "does not clear parent set by another mechanism when removal has no prior inline declaration" do
        parent = create(:issue, project: project, github_number: 8213)
        # Parent was set externally (e.g. parent-listing), not via inline declaration
        child = create(:issue, project: project, body: "Some body text", parent_issue_id: parent.id)

        # A removal comment for the stored parent should not clear it because
        # there was no inline parent declaration — the declared flag stays false.
        described_class.call(
          issue: child,
          comments: [ "No longer part of #8213" ]
        )

        expect(child.reload.parent_issue_id).to eq(parent.id)
      end

      it "handles nil comments gracefully" do
        parent = create(:issue, project: project, body: "## Child Issues\n- #8230")

        expect { described_class.call(issue: parent, comments: nil) }.not_to raise_error
      end

      it "skips blank comments" do
        parent = create(:issue, project: project, body: "## Child Issues\n- #8240")

        expect { described_class.call(issue: parent, comments: [ "", nil, "  " ]) }.not_to raise_error
      end
    end

    describe "interaction between child listing and parent declaration" do
      it "handles both directions independently" do
        grandparent = create(:issue, project: project, github_number: 8300)
        child = create(:issue, project: project, github_number: 8301)
        issue = create(:issue, project: project, body: "Part of #8300\n\n## Child Issues\n- #8301")

        described_class.call(issue: issue)

        expect(issue.reload.parent_issue_id).to eq(grandparent.id)
        expect(child.reload.parent_issue_id).to eq(issue.id)
      end
    end
  end
end
