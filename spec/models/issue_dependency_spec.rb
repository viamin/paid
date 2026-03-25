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

    it "allows dependencies across projects within the same account" do
      account = create(:account)
      project_a = create(:project, account: account)
      project_b = create(:project, account: account)
      issue = create(:issue, project: project_a)
      other_issue = create(:issue, project: project_b)

      dep = build(:issue_dependency, issue: issue, depends_on_issue: other_issue)

      expect(dep).to be_valid
    end

    it "rejects dependencies across different accounts" do
      issue = create(:issue)
      other_issue = create(:issue)

      dep = build(:issue_dependency, issue: issue, depends_on_issue: other_issue)

      expect(dep).not_to be_valid
      expect(dep.errors[:depends_on_issue]).to include("must belong to the same account")
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

    it "rejects duplicate external references for the same issue" do
      issue = create(:issue)
      create(:issue_dependency, issue: issue, depends_on_issue: nil,
                                depends_on_owner: "viamin", depends_on_repo: "agent-harness",
                                depends_on_number: 31)
      dup = build(:issue_dependency, issue: issue, depends_on_issue: nil,
                                     depends_on_owner: "viamin", depends_on_repo: "agent-harness",
                                     depends_on_number: 31)

      expect(dup).not_to be_valid
      expect(dup.errors[:depends_on_owner]).to include("has already been taken")
    end

    it "normalizes external owner/repo to lowercase before validation" do
      issue = create(:issue)
      dep = build(:issue_dependency, issue: issue, depends_on_issue: nil,
                                     depends_on_owner: "Viamin", depends_on_repo: "Agent-Harness",
                                     depends_on_number: 31)

      dep.valid?
      expect(dep.depends_on_owner).to eq("viamin")
      expect(dep.depends_on_repo).to eq("agent-harness")
    end

    it "normalizes blank strings to nil in external columns" do
      issue = create(:issue)
      other_issue = create(:issue, project: issue.project)
      dep = build(:issue_dependency, issue: issue, depends_on_issue: other_issue,
                                     depends_on_owner: "", depends_on_repo: "",
                                     depends_on_number: nil)

      dep.valid?
      expect(dep.depends_on_owner).to be_nil
      expect(dep.depends_on_repo).to be_nil
    end

    it "rejects records with both local and external references" do
      issue = create(:issue)
      other_issue = create(:issue, project: issue.project)
      dep = build(:issue_dependency, issue: issue, depends_on_issue: other_issue,
                                     depends_on_owner: "viamin", depends_on_repo: "agent-harness",
                                     depends_on_number: 31)

      expect(dep).not_to be_valid
      expect(dep.errors[:base]).to include("cannot reference both a local issue and an external issue")
    end

    it "rejects records with local issue and partial external columns" do
      issue = create(:issue)
      other_issue = create(:issue, project: issue.project)
      dep = build(:issue_dependency, issue: issue, depends_on_issue: other_issue,
                                     depends_on_owner: nil, depends_on_repo: "agent-harness",
                                     depends_on_number: nil)

      expect(dep).not_to be_valid
      expect(dep.errors[:base]).to include("cannot reference both a local issue and an external issue")
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
      account = create(:account)
      project_a = create(:project, account: account)
      project_b = create(:project, account: account)
      issue_a = create(:issue, project: project_a)
      issue_b = create(:issue, project: project_b)
      create(:issue_dependency, issue: issue_a, depends_on_issue: issue_b)

      adj = described_class.global_adjacency
      expect(adj[issue_a.id]).to include(issue_b.id)
    end
  end

  describe ".account_adjacency" do
    it "includes dependencies within the account" do
      account = create(:account)
      project_a = create(:project, account: account)
      project_b = create(:project, account: account)
      issue_a = create(:issue, project: project_a)
      issue_b = create(:issue, project: project_b)
      create(:issue_dependency, issue: issue_a, depends_on_issue: issue_b)

      adj = described_class.account_adjacency(account)
      expect(adj[issue_a.id]).to include(issue_b.id)
    end

    it "excludes dependencies from other accounts" do
      account = create(:account)
      other_account = create(:account)
      other_project = create(:project, account: other_account)
      other_issue_a = create(:issue, project: other_project)
      other_issue_b = create(:issue, project: other_project)
      create(:issue_dependency, issue: other_issue_a, depends_on_issue: other_issue_b)

      adj = described_class.account_adjacency(account)
      expect(adj).to be_empty
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
