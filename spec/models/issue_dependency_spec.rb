# frozen_string_literal: true

require "rails_helper"

RSpec.describe IssueDependency do
  describe "associations" do
    it { is_expected.to belong_to(:issue) }
    it { is_expected.to belong_to(:depends_on_issue).class_name("Issue").optional }
  end

  describe "validations" do
    subject { build(:issue_dependency) }

    it { is_expected.to validate_uniqueness_of(:depends_on_issue_id).scoped_to(:issue_id) }

    it "rejects self-referential dependencies" do
      issue = create(:issue)
      dep = build(:issue_dependency, issue: issue, depends_on_issue: issue)

      expect(dep).not_to be_valid
      expect(dep.errors[:depends_on_issue]).to include("cannot be the same as the issue")
    end

    it "allows dependencies across projects" do
      issue = create(:issue)
      other_issue = create(:issue)

      dep = build(:issue_dependency, issue: issue, depends_on_issue: other_issue)

      expect(dep).to be_valid
    end

    it "allows dependencies within the same project" do
      project = create(:project)
      issue_a = create(:issue, project: project)
      issue_b = create(:issue, project: project)

      dep = build(:issue_dependency, issue: issue_a, depends_on_issue: issue_b)

      expect(dep).to be_valid
    end

    it "requires either a local issue or external reference" do
      issue = create(:issue)
      dep = build(:issue_dependency, issue: issue, depends_on_issue: nil,
                                     depends_on_owner: nil, depends_on_repo: nil, depends_on_number: nil)

      expect(dep).not_to be_valid
      expect(dep.errors[:base]).to include("must reference a local issue or an external issue (owner/repo#number)")
    end

    it "accepts a complete external reference" do
      issue = create(:issue)
      dep = build(:issue_dependency, issue: issue, depends_on_issue: nil,
                                     depends_on_owner: "viamin", depends_on_repo: "agent-harness",
                                     depends_on_number: 31)

      expect(dep).to be_valid
    end

    it "rejects an incomplete external reference" do
      issue = create(:issue)
      dep = build(:issue_dependency, issue: issue, depends_on_issue: nil,
                                     depends_on_owner: "viamin", depends_on_repo: nil,
                                     depends_on_number: 31)

      expect(dep).not_to be_valid
    end
  end

  describe "#external?" do
    it "returns true for external dependencies" do
      dep = build(:issue_dependency, depends_on_issue: nil,
                                     depends_on_owner: "viamin", depends_on_repo: "agent-harness",
                                     depends_on_number: 31)
      expect(dep).to be_external
    end

    it "returns false for local dependencies" do
      dep = build(:issue_dependency)
      expect(dep).not_to be_external
    end
  end

  describe "#external_ref" do
    it "returns the formatted reference for external deps" do
      dep = build(:issue_dependency, depends_on_issue: nil,
                                     depends_on_owner: "viamin", depends_on_repo: "agent-harness",
                                     depends_on_number: 31)
      expect(dep.external_ref).to eq("viamin/agent-harness#31")
    end

    it "returns nil for local deps" do
      dep = build(:issue_dependency)
      expect(dep.external_ref).to be_nil
    end
  end

  describe ".global_adjacency" do
    it "builds adjacency across all projects" do
      project_a = create(:project)
      project_b = create(:project)
      issue_a = create(:issue, project: project_a)
      issue_b = create(:issue, project: project_b)
      create(:issue_dependency, issue: issue_a, depends_on_issue: issue_b)

      adj = described_class.global_adjacency
      expect(adj[issue_a.id]).to include(issue_b.id)
    end
  end

  describe "cascade deletion" do
    it "is destroyed when the dependent issue is destroyed" do
      project = create(:project)
      issue_a = create(:issue, project: project)
      issue_b = create(:issue, project: project)
      create(:issue_dependency, issue: issue_a, depends_on_issue: issue_b)

      expect { issue_a.destroy }.to change(described_class, :count).by(-1)
    end

    it "is destroyed when the dependency issue is destroyed" do
      project = create(:project)
      issue_a = create(:issue, project: project)
      issue_b = create(:issue, project: project)
      create(:issue_dependency, issue: issue_a, depends_on_issue: issue_b)

      expect { issue_b.destroy }.to change(described_class, :count).by(-1)
    end
  end
end
