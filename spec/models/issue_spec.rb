# frozen_string_literal: true

require "rails_helper"

RSpec.describe Issue do
  describe "associations" do
    it { is_expected.to belong_to(:project) }
    it { is_expected.to belong_to(:parent_issue).class_name("Issue").optional }
    it { is_expected.to have_many(:sub_issues).class_name("Issue").with_foreign_key(:parent_issue_id).dependent(:nullify) }
    it { is_expected.to have_many(:agent_runs).dependent(:nullify) }
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
  end

  describe "instance methods" do
    describe "#github_url" do
      it "returns the GitHub issue URL" do
        project = build(:project, owner: "viamin", repo: "paid")
        issue = build(:issue, project: project, github_number: 42)

        expect(issue.github_url).to eq("https://github.com/viamin/paid/issues/42")
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
end
