# frozen_string_literal: true

require "rails_helper"

RSpec.describe Issue do
  describe "associations" do
    it { is_expected.to belong_to(:project) }
    it { is_expected.to belong_to(:parent_issue).class_name("Issue").optional }
    it { is_expected.to have_many(:sub_issues).class_name("Issue").with_foreign_key(:parent_issue_id).dependent(:nullify) }
    it { is_expected.to have_many(:agent_runs).dependent(:nullify) }
    it { is_expected.to have_many(:issue_dependencies).dependent(:destroy) }
    it { is_expected.to have_many(:dependencies).through(:issue_dependencies) }
    it { is_expected.to have_many(:reverse_issue_dependencies).class_name("IssueDependency").dependent(:destroy) }
    it { is_expected.to have_many(:dependents).through(:reverse_issue_dependencies) }
  end

  describe "validations" do
    subject { build(:issue) }

    it { is_expected.to validate_presence_of(:github_issue_id) }
    it { is_expected.to validate_uniqueness_of(:github_issue_id).scoped_to(:project_id) }
    it { is_expected.to validate_presence_of(:github_number) }
    it { is_expected.to validate_presence_of(:title) }
    it { is_expected.to validate_length_of(:title).is_at_most(1000) }
    it { is_expected.to validate_presence_of(:github_state) }
    it { is_expected.to validate_presence_of(:github_created_at) }
    it { is_expected.to validate_presence_of(:github_updated_at) }
    it { is_expected.to validate_presence_of(:paid_state) }
    it { is_expected.to validate_inclusion_of(:paid_state).in_array(described_class::PAID_STATES) }

    describe "parent_issue project validation" do
      it "allows parent_issue from the same project" do
        project = create(:project)
        parent = create(:issue, project: project)
        issue = build(:issue, project: project, parent_issue: parent)

        expect(issue).to be_valid
      end

      it "rejects parent_issue from a different project" do
        project = create(:project)
        other_project = create(:project)
        parent = create(:issue, project: other_project)
        issue = build(:issue, project: project, parent_issue: parent)

        expect(issue).not_to be_valid
        expect(issue.errors[:parent_issue]).to include("must belong to the same project")
      end

      it "allows nil parent_issue" do
        issue = build(:issue, parent_issue: nil)

        expect(issue).to be_valid
      end
    end
  end

  describe "scopes" do
    describe ".by_paid_state" do
      it "returns issues with the specified paid_state" do
        planning_issue = create(:issue, :planning)
        create(:issue, :in_progress)

        expect(described_class.by_paid_state("planning")).to include(planning_issue)
        expect(described_class.by_paid_state("planning").count).to eq(1)
      end
    end

    describe ".root_issues" do
      it "includes issues without a parent" do
        root_issue = create(:issue)
        expect(described_class.root_issues).to include(root_issue)
      end

      it "excludes sub-issues" do
        sub_issue = create(:issue, :sub_issue)
        expect(described_class.root_issues).not_to include(sub_issue)
      end
    end

    describe ".sub_issues_only" do
      it "includes sub-issues" do
        sub_issue = create(:issue, :sub_issue)
        expect(described_class.sub_issues_only).to include(sub_issue)
      end

      it "excludes root issues" do
        root_issue = create(:issue)
        expect(described_class.sub_issues_only).not_to include(root_issue)
      end
    end

    describe ".issues_only" do
      it "includes issues" do
        issue = create(:issue)
        expect(described_class.issues_only).to include(issue)
      end

      it "excludes pull requests" do
        pr = create(:issue, :pull_request)
        expect(described_class.issues_only).not_to include(pr)
      end
    end

    describe ".pull_requests_only" do
      it "includes pull requests" do
        pr = create(:issue, :pull_request)
        expect(described_class.pull_requests_only).to include(pr)
      end

      it "excludes issues" do
        issue = create(:issue)
        expect(described_class.pull_requests_only).not_to include(issue)
      end
    end

    describe ".ready_for_work" do
      let(:project) { create(:project) }

      it "returns open issues with no dependencies" do
        issue = create(:issue, project: project)

        expect(described_class.ready_for_work(project)).to include(issue)
      end

      it "excludes issues with open dependencies" do
        dep = create(:issue, project: project, github_state: "open")
        issue = create(:issue, project: project)
        create(:issue_dependency, issue: issue, depends_on_issue: dep)

        expect(described_class.ready_for_work(project)).not_to include(issue)
      end

      it "includes issues whose dependencies are all closed" do
        dep = create(:issue, project: project, github_state: "closed")
        issue = create(:issue, project: project)
        create(:issue_dependency, issue: issue, depends_on_issue: dep)

        expect(described_class.ready_for_work(project)).to include(issue)
      end

      it "excludes closed issues" do
        issue = create(:issue, project: project, github_state: "closed")

        expect(described_class.ready_for_work(project)).not_to include(issue)
      end

      it "excludes pull requests" do
        pr = create(:issue, :pull_request, project: project)

        expect(described_class.ready_for_work(project)).not_to include(pr)
      end

      it "excludes issues from other projects" do
        other_project = create(:project)
        issue = create(:issue, project: other_project)

        expect(described_class.ready_for_work(project)).not_to include(issue)
      end

      it "excludes issues with unresolved external dependencies" do
        issue = create(:issue, project: project)
        create(:issue_dependency, issue: issue, depends_on_issue: nil,
                                  depends_on_owner: "org", depends_on_repo: "repo",
                                  depends_on_number: 42)

        expect(described_class.ready_for_work(project)).not_to include(issue)
      end
    end
  end

  describe "instance methods" do
    describe "#github_url" do
      it "returns the GitHub issue URL for issues" do
        project = build(:project, owner: "viamin", repo: "paid")
        issue = build(:issue, project: project, github_number: 42)

        expect(issue.github_url).to eq("https://github.com/viamin/paid/issues/42")
      end

      it "returns the GitHub pull request URL for PRs" do
        project = build(:project, owner: "viamin", repo: "paid")
        pr = build(:issue, :pull_request, project: project, github_number: 43)

        expect(pr.github_url).to eq("https://github.com/viamin/paid/pull/43")
      end
    end

    describe "#has_label?" do
      it "returns true when the label is present" do
        issue = build(:issue, :with_labels)

        expect(issue.has_label?("bug")).to be true
      end

      it "returns false when the label is absent" do
        issue = build(:issue, labels: [ "bug" ])

        expect(issue.has_label?("enhancement")).to be false
      end

      it "returns false for empty labels" do
        issue = build(:issue, labels: [])

        expect(issue.has_label?("bug")).to be false
      end
    end

    describe "#draft_phase?" do
      it "returns true for draft phase" do
        pr = build(:issue, :pull_request, pr_review_phase: "draft")

        expect(pr.draft_phase?).to be true
      end

      it "returns true for restarted phase" do
        pr = build(:issue, :pull_request, pr_review_phase: "restarted")

        expect(pr.draft_phase?).to be true
      end

      it "returns false for ready phase" do
        pr = build(:issue, :pull_request, pr_review_phase: "ready")

        expect(pr.draft_phase?).to be false
      end

      it "returns false for escalated phase" do
        pr = build(:issue, :pull_request, pr_review_phase: "escalated")

        expect(pr.draft_phase?).to be false
      end
    end

    describe "#sub_issue?" do
      it "returns true when issue has a parent" do
        issue = build(:issue, :sub_issue)

        expect(issue.sub_issue?).to be true
      end

      it "returns false when issue has no parent" do
        issue = build(:issue)

        expect(issue.sub_issue?).to be false
      end
    end

    describe "#has_associated_pull_requests?" do
      let(:project) { create(:project) }

      it "returns true when issue has a sub-issue that is a pull request" do
        issue = create(:issue, project: project)
        create(:issue, :pull_request, project: project, parent_issue: issue)

        expect(issue.has_associated_pull_requests?).to be true
      end

      it "returns false when issue has no sub-issues" do
        issue = create(:issue, project: project)

        expect(issue.has_associated_pull_requests?).to be false
      end

      it "returns false when issue has sub-issues that are not pull requests" do
        issue = create(:issue, project: project)
        create(:issue, project: project, parent_issue: issue)

        expect(issue.has_associated_pull_requests?).to be false
      end

      context "when sub_issues are preloaded" do
        it "returns true when preloaded sub-issues include a pull request" do
          issue = create(:issue, project: project)
          create(:issue, :pull_request, project: project, parent_issue: issue)

          preloaded_issue = described_class.includes(:sub_issues).find(issue.id)

          expect(preloaded_issue.sub_issues).to be_loaded
          expect(preloaded_issue.has_associated_pull_requests?).to be true
        end

        it "returns false when preloaded sub-issues have no pull requests" do
          issue = create(:issue, project: project)
          create(:issue, project: project, parent_issue: issue)

          preloaded_issue = described_class.includes(:sub_issues).find(issue.id)

          expect(preloaded_issue.sub_issues).to be_loaded
          expect(preloaded_issue.has_associated_pull_requests?).to be false
        end
      end
    end
  end

  describe "#ready_to_work?" do
    let(:project) { create(:project) }

    it "returns true when issue has no dependencies" do
      issue = create(:issue, project: project)

      expect(issue.ready_to_work?).to be true
    end

    it "returns false when issue has open dependencies" do
      dep = create(:issue, project: project, github_state: "open")
      issue = create(:issue, project: project)
      create(:issue_dependency, issue: issue, depends_on_issue: dep)

      expect(issue.ready_to_work?).to be false
    end

    it "returns true when all dependencies are closed" do
      dep = create(:issue, project: project, github_state: "closed")
      issue = create(:issue, project: project)
      create(:issue_dependency, issue: issue, depends_on_issue: dep)

      expect(issue.ready_to_work?).to be true
    end

    it "returns false when issue has unresolved external dependencies" do
      issue = create(:issue, project: project)
      create(:issue_dependency, issue: issue, depends_on_issue: nil,
                                depends_on_owner: "org", depends_on_repo: "repo",
                                depends_on_number: 42)

      expect(issue.ready_to_work?).to be false
    end

    it "returns false when issue has both closed local and unresolved external dependencies" do
      dep = create(:issue, project: project, github_state: "closed")
      issue = create(:issue, project: project)
      create(:issue_dependency, issue: issue, depends_on_issue: dep)
      create(:issue_dependency, issue: issue, depends_on_issue: nil,
                                depends_on_owner: "org", depends_on_repo: "repo",
                                depends_on_number: 42)

      expect(issue.ready_to_work?).to be false
    end
  end

  describe "#blocking_issues" do
    let(:project) { create(:project) }

    it "returns only open dependencies" do
      open_dep = create(:issue, project: project, github_state: "open")
      closed_dep = create(:issue, project: project, github_state: "closed")
      issue = create(:issue, project: project)
      create(:issue_dependency, issue: issue, depends_on_issue: open_dep)
      create(:issue_dependency, issue: issue, depends_on_issue: closed_dep)

      expect(issue.blocking_issues).to contain_exactly(open_dep)
    end
  end

  describe "#dependent_issues" do
    let(:project) { create(:project) }

    it "returns issues that depend on this issue" do
      issue = create(:issue, project: project)
      dependent = create(:issue, project: project)
      create(:issue_dependency, issue: dependent, depends_on_issue: issue)

      expect(issue.dependent_issues).to contain_exactly(dependent)
    end
  end

  describe "#trusted? and #untrusted?" do
    let(:project) { create(:project, allowed_github_usernames: [ "viamin" ]) }

    it "returns trusted? true for allowlisted creator" do
      issue = build(:issue, project: project, github_creator_login: "viamin")

      expect(issue.trusted?).to be true
      expect(issue.untrusted?).to be false
    end

    it "returns trusted? false for non-allowlisted creator" do
      issue = build(:issue, project: project, github_creator_login: "attacker")

      expect(issue.trusted?).to be false
      expect(issue.untrusted?).to be true
    end

    it "is case-insensitive" do
      issue = build(:issue, project: project, github_creator_login: "VIAMIN")

      expect(issue.trusted?).to be true
    end
  end

  describe "github_creator_login validation" do
    it "requires github_creator_login" do
      issue = build(:issue, github_creator_login: nil)

      expect(issue).not_to be_valid
      expect(issue.errors[:github_creator_login]).to include("can't be blank")
    end
  end

  describe "labels JSONB storage" do
    it "stores labels as JSONB array" do
      labels = [ "paid:planning", "bug", "priority:high" ]
      issue = create(:issue, labels: labels)
      reloaded = described_class.find(issue.id)

      expect(reloaded.labels).to eq(labels)
    end

    it "defaults to empty array" do
      issue = create(:issue)
      issue.reload
      expect(issue.labels).to eq([])
    end
  end

  describe "project association" do
    it "is destroyed when project is destroyed" do
      project = create(:project)
      issue = create(:issue, project: project)

      expect { project.destroy }.to change(described_class, :count).by(-1)
      expect { issue.reload }.to raise_error(ActiveRecord::RecordNotFound)
    end
  end

  describe "sub_issues association" do
    it "nullifies parent_issue_id when parent issue is destroyed" do
      parent = create(:issue)
      sub_issue = create(:issue, project: parent.project, parent_issue: parent)

      parent.destroy
      sub_issue.reload

      expect(sub_issue.parent_issue_id).to be_nil
    end
  end

  describe "paid state machine values" do
    it "defines valid PAID_STATES" do
      expect(described_class::PAID_STATES).to eq(%w[new planning in_progress completed failed])
    end

    it "defaults paid_state to new" do
      issue = create(:issue)
      expect(issue.paid_state).to eq("new")
    end

    it "accepts all valid paid states" do
      described_class::PAID_STATES.each do |state|
        issue = build(:issue, paid_state: state)
        expect(issue).to be_valid
      end
    end

    it "rejects invalid paid states" do
      issue = build(:issue, paid_state: "invalid")
      expect(issue).not_to be_valid
      expect(issue.errors[:paid_state]).to include("is not included in the list")
    end
  end

  describe "broadcast callbacks" do
    let(:project) { create(:project) }

    context "when creating an issue" do
      it "broadcasts issues update for a regular issue" do
        allow(project).to receive(:broadcast_issues_update)
        allow(project).to receive(:broadcast_pull_requests_update)

        create(:issue, project: project)

        expect(project).to have_received(:broadcast_issues_update)
        expect(project).not_to have_received(:broadcast_pull_requests_update)
      end

      it "broadcasts pull requests update for a pull request" do
        allow(project).to receive(:broadcast_issues_update)
        allow(project).to receive(:broadcast_pull_requests_update)

        create(:issue, :pull_request, project: project)

        expect(project).not_to have_received(:broadcast_issues_update)
        expect(project).to have_received(:broadcast_pull_requests_update)
      end

      it "broadcasts both sections for a pull request linked to an issue" do
        parent = create(:issue, project: project)
        allow(project).to receive(:broadcast_issues_update)
        allow(project).to receive(:broadcast_pull_requests_update)

        create(:issue, :pull_request, project: project, parent_issue: parent)

        expect(project).to have_received(:broadcast_issues_update)
        expect(project).to have_received(:broadcast_pull_requests_update)
      end
    end

    context "when updating an issue" do
      it "broadcasts issues update for a regular issue" do
        allow(project).to receive(:broadcast_issues_update)
        allow(project).to receive(:broadcast_pull_requests_update)
        issue = create(:issue, project: project)

        expect(project).to receive(:broadcast_issues_update).once
        expect(project).not_to receive(:broadcast_pull_requests_update)

        issue.update!(title: "Updated title")
      end

      it "broadcasts pull requests update for a pull request" do
        allow(project).to receive(:broadcast_issues_update)
        allow(project).to receive(:broadcast_pull_requests_update)
        pr = create(:issue, :pull_request, project: project)

        expect(project).not_to receive(:broadcast_issues_update)
        expect(project).to receive(:broadcast_pull_requests_update).once

        pr.update!(title: "Updated PR title")
      end

      it "broadcasts issues update when a PR is linked to an issue" do
        parent = create(:issue, project: project)
        allow(project).to receive(:broadcast_issues_update)
        allow(project).to receive(:broadcast_pull_requests_update)
        pr = create(:issue, :pull_request, project: project)

        expect(project).to receive(:broadcast_issues_update).once
        expect(project).to receive(:broadcast_pull_requests_update).once

        pr.update!(parent_issue_id: parent.id)
      end

      it "broadcasts issues update when a PR is unlinked from an issue" do
        parent = create(:issue, project: project)
        allow(project).to receive(:broadcast_issues_update)
        allow(project).to receive(:broadcast_pull_requests_update)
        pr = create(:issue, :pull_request, project: project, parent_issue: parent)

        expect(project).to receive(:broadcast_issues_update).once
        expect(project).to receive(:broadcast_pull_requests_update).once

        pr.update!(parent_issue_id: nil)
      end

      it "does not broadcast issues update when a linked PR title changes" do
        parent = create(:issue, project: project)
        allow(project).to receive(:broadcast_issues_update)
        allow(project).to receive(:broadcast_pull_requests_update)
        pr = create(:issue, :pull_request, project: project, parent_issue: parent)

        expect(project).not_to receive(:broadcast_issues_update)
        expect(project).to receive(:broadcast_pull_requests_update).once

        pr.update!(title: "Updated PR title")
      end

      it "broadcasts both sections when is_pull_request changes" do
        allow(project).to receive(:broadcast_issues_update)
        allow(project).to receive(:broadcast_pull_requests_update)
        issue = create(:issue, project: project, is_pull_request: false)

        expect(project).to receive(:broadcast_issues_update).once
        expect(project).to receive(:broadcast_pull_requests_update).once

        issue.update!(is_pull_request: true)
      end
    end

    context "when destroying an issue" do
      it "broadcasts issues update for a regular issue" do
        allow(project).to receive(:broadcast_issues_update)
        allow(project).to receive(:broadcast_pull_requests_update)
        issue = create(:issue, project: project)

        expect(project).to receive(:broadcast_issues_update).once
        expect(project).not_to receive(:broadcast_pull_requests_update)

        issue.destroy!
      end

      it "broadcasts pull requests update for a pull request" do
        allow(project).to receive(:broadcast_issues_update)
        allow(project).to receive(:broadcast_pull_requests_update)
        pr = create(:issue, :pull_request, project: project)

        expect(project).not_to receive(:broadcast_issues_update)
        expect(project).to receive(:broadcast_pull_requests_update).once

        pr.destroy!
      end

      it "broadcasts both sections when destroying a PR linked to an issue" do
        parent = create(:issue, project: project)
        allow(project).to receive(:broadcast_issues_update)
        allow(project).to receive(:broadcast_pull_requests_update)
        pr = create(:issue, :pull_request, project: project, parent_issue: parent)

        expect(project).to receive(:broadcast_issues_update).once
        expect(project).to receive(:broadcast_pull_requests_update).once

        pr.destroy!
      end
    end
  end
end
