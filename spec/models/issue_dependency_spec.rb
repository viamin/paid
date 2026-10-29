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

    # @spec DEPENDENCY-DECLARATIONS-008
    it "rejects a two-node blocking cycle with its exact path" do
      project = create(:project)
      issue_a = create(:issue, project: project, github_number: 701)
      issue_b = create(:issue, project: project, github_number: 702)
      create(:issue_dependency, issue: issue_b, depends_on_issue: issue_a)

      dep = build(:issue_dependency, issue: issue_a, depends_on_issue: issue_b)

      expect(dep).not_to be_valid
      expect(dep.errors[:depends_on_issue]).to include("creates a blocking dependency cycle: #701 -> #702 -> #701 (source: direct_write)")
    end

    # @spec DEPENDENCY-DECLARATIONS-008
    it "allows a parent dependency when the child has a contextual parent reference" do
      project = create(:project)
      parent = create(:issue, project: project, github_number: 705)
      child = create(:issue, project: project, github_number: 706, parent_issue: parent)
      create(:issue_dependency, issue: child, depends_on_issue: parent)

      dep = build(:issue_dependency, issue: parent, depends_on_issue: child)

      expect(dep).to be_valid
    end

    # @spec DEPENDENCY-DECLARATIONS-008
    it "allows a parent dependency when a contextual external reference resolves locally" do
      project = create(:project, owner: "acme", repo: "paid")
      parent = create(:issue, project: project, github_number: 707)
      child = create(:issue, project: project, github_number: 708, parent_issue: parent)
      create(:issue_dependency, issue: child, depends_on_issue: nil,
        depends_on_owner: "acme", depends_on_repo: "paid", depends_on_number: parent.github_number)

      dep = build(:issue_dependency, issue: parent, depends_on_issue: child)

      expect(dep).to be_valid
    end

    # @spec DEPENDENCY-DECLARATIONS-008
    it "rejects a cross-project multi-node cycle within one account" do
      account = create(:account)
      first_project = create(:project, account: account)
      second_project = create(:project, account: account)
      issue_a = create(:issue, project: first_project, github_number: 711)
      issue_b = create(:issue, project: second_project, github_number: 712)
      issue_c = create(:issue, project: first_project, github_number: 713)
      create(:issue_dependency, issue: issue_b, depends_on_issue: issue_c)
      create(:issue_dependency, issue: issue_c, depends_on_issue: issue_a)

      dep = build(:issue_dependency, issue: issue_a, depends_on_issue: issue_b)

      expect(dep).not_to be_valid
      expect(dep.errors[:depends_on_issue]).to include(a_string_including("#711 -> #712 -> #713 -> #711 (source: direct_write)"))
    end

    # @spec DEPENDENCY-DECLARATIONS-008
    it "rejects an external declaration when its target later resolves locally" do
      account = create(:account)
      project_a = create(:project, account: account)
      project_b = create(:project, account: account, owner: "acme", repo: "other")
      issue_a = create(:issue, project: project_a, github_number: 721)
      issue_b = create(:issue, project: project_b, github_number: 722)
      create(:issue_dependency, issue: issue_b, depends_on_issue: issue_a)

      dep = build(:issue_dependency, issue: issue_a, depends_on_owner: "acme", depends_on_repo: "other", depends_on_number: 722)

      expect(dep).not_to be_valid
      expect(dep.errors[:depends_on_issue]).to include(a_string_including("#721 -> #722 -> #721"))
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

    it "rejects external dependency with depends_on_number zero" do
      issue = create(:issue)
      dep = build(:issue_dependency, issue: issue, depends_on_issue: nil,
                                     depends_on_owner: "viamin", depends_on_repo: "agent-harness",
                                     depends_on_number: 0)

      expect(dep).not_to be_valid
      expect(dep.errors[:depends_on_number]).to include("must be greater than 0")
    end

    it "rejects external dependency with negative depends_on_number" do
      issue = create(:issue)
      dep = build(:issue_dependency, issue: issue, depends_on_issue: nil,
                                     depends_on_owner: "viamin", depends_on_repo: "agent-harness",
                                     depends_on_number: -1)

      expect(dep).not_to be_valid
      expect(dep.errors[:depends_on_number]).to include("must be greater than 0")
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

  describe "#deployment_pending?" do
    let(:project) { create(:project) }
    let(:issue) { create(:issue, project: project) }

    it "returns false when requires_deployment is false" do
      pr = create(:issue, :pull_request, :closed, project: project, deployed_at: nil)
      dep = create(:issue_dependency, issue: issue, depends_on_issue: pr, requires_deployment: false)

      expect(dep).not_to be_deployment_pending
    end

    it "returns false when target is still open (regular blocking path applies)" do
      pr = create(:issue, :pull_request, project: project, github_state: "open", deployed_at: nil)
      dep = create(:issue_dependency, issue: issue, depends_on_issue: pr, requires_deployment: true)

      expect(dep).not_to be_deployment_pending
    end

    it "returns false when target is not a pull request" do
      non_pr = create(:issue, :closed, project: project)
      dep = create(:issue_dependency, issue: issue, depends_on_issue: non_pr, requires_deployment: true)

      expect(dep).not_to be_deployment_pending
    end

    it "returns true when target PR has merged but has no deployed_at" do
      pr = create(:issue, :pull_request, :closed, project: project, deployed_at: nil)
      dep = create(:issue_dependency, issue: issue, depends_on_issue: pr, requires_deployment: true)

      expect(dep).to be_deployment_pending
    end

    it "returns false when target PR has been marked deployed" do
      pr = create(:issue, :pull_request, :closed, project: project, deployed_at: Time.current)
      dep = create(:issue_dependency, issue: issue, depends_on_issue: pr, requires_deployment: true)

      expect(dep).not_to be_deployment_pending
    end

    it "returns false for external deps (deployment cannot be observed)" do
      dep = create(:issue_dependency, issue: issue, depends_on_issue: nil,
                                       depends_on_owner: "viamin", depends_on_repo: "agent-harness",
                                       depends_on_number: 31, requires_deployment: true)

      expect(dep).not_to be_deployment_pending
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
