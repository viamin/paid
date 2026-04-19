# frozen_string_literal: true

require "rails_helper"

RSpec.describe PrTemplate do
  describe "associations" do
    it { is_expected.to belong_to(:account) }
    it { is_expected.to belong_to(:project).optional }
    it { is_expected.to belong_to(:user).optional }
  end

  describe "validations" do
    subject { build(:pr_template) }

    it { is_expected.to validate_presence_of(:name) }
    it { is_expected.to validate_length_of(:name).is_at_most(255) }
    it { is_expected.to validate_presence_of(:body) }
    it { is_expected.to validate_presence_of(:pr_type) }
    it { is_expected.to validate_inclusion_of(:pr_type).in_array(described_class::PR_TYPES) }
    it { is_expected.to validate_numericality_of(:position).only_integer.is_greater_than_or_equal_to(0) }

    it "validates uniqueness of name scoped to account" do
      account = create(:account)
      create(:pr_template, account: account, name: "standard")
      duplicate = build(:pr_template, account: account, name: "standard")

      expect(duplicate).not_to be_valid
      expect(duplicate.errors[:name]).to include("has already been taken")
    end

    it "allows same name in different projects" do
      account = create(:account)
      project1 = create(:project, account: account)
      project2 = create(:project, account: account)

      create(:pr_template, account: account, project: project1, name: "standard")
      template = build(:pr_template, account: account, project: project2, name: "standard")

      expect(template).to be_valid
    end

    it "validates project belongs to account" do
      account1 = create(:account)
      account2 = create(:account)
      project = create(:project, account: account2)

      template = build(:pr_template, account: account1, project: project, name: "standard")
      template.valid?

      expect(template.errors[:project]).to include("must belong to the same account")
    end

    it "validates user belongs to account" do
      account1 = create(:account)
      account2 = create(:account)
      user = create(:user, account: account2)

      template = build(:pr_template, account: account1, user: user, name: "standard")
      template.valid?

      expect(template.errors[:user]).to include("must belong to the same account")
    end

    it "rejects both project and user being set" do
      account = create(:account)
      project = create(:project, account: account)
      user = create(:user, account: account)

      template = build(:pr_template, account: account, project: project, user: user)
      template.valid?

      expect(template.errors[:base]).to include("cannot be scoped to both a project and a user")
    end
  end

  describe "scopes" do
    let(:account) { create(:account) }
    let(:project) { create(:project, account: account) }
    let(:user) { create(:user, account: account) }

    describe ".enabled" do
      it "returns only enabled templates" do
        enabled = create(:pr_template, account: account, enabled: true)
        create(:pr_template, account: account, enabled: false)

        expect(described_class.enabled).to eq([ enabled ])
      end
    end

    describe ".ordered" do
      it "orders by position then name" do
        c = create(:pr_template, account: account, name: "c-template", position: 0)
        a = create(:pr_template, account: account, name: "a-template", position: 1)
        b = create(:pr_template, account: account, name: "b-template", position: 0)

        expect(described_class.ordered).to eq([ b, c, a ])
      end
    end

    describe ".for_account" do
      it "returns account-level templates" do
        account_tmpl = create(:pr_template, account: account)
        create(:pr_template, account: account, project: project)

        expect(described_class.for_account(account)).to eq([ account_tmpl ])
      end
    end

    describe ".for_project" do
      it "returns project-level templates" do
        create(:pr_template, account: account)
        project_tmpl = create(:pr_template, account: account, project: project)

        expect(described_class.for_project(project)).to eq([ project_tmpl ])
      end
    end

    describe ".for_user" do
      it "returns user-level templates" do
        create(:pr_template, account: account)
        user_tmpl = create(:pr_template, account: account, user: user)

        expect(described_class.for_user(user)).to eq([ user_tmpl ])
      end
    end
  end

  describe "#account_level?" do
    it "returns true when no project or user" do
      template = build(:pr_template)
      expect(template).to be_account_level
    end

    it "returns false when project is set" do
      project = create(:project)
      template = build(:pr_template, account: project.account, project: project)
      expect(template).not_to be_account_level
    end
  end

  describe "#project_level?" do
    it "returns true when project is set" do
      project = create(:project)
      template = build(:pr_template, account: project.account, project: project)
      expect(template).to be_project_level
    end
  end

  describe "#user_level?" do
    it "returns true when user is set and no project" do
      user = create(:user)
      template = build(:pr_template, account: user.account, user: user)
      expect(template).to be_user_level
    end
  end

  describe ".resolve" do
    let(:account) { create(:account) }
    let(:user) { create(:user, account: account) }
    let(:project) { create(:project, account: account) }

    it "returns account-level template when no overrides" do
      template = create(:pr_template, account: account, name: "standard")

      result = described_class.resolve(project: project, user: user)

      expect(result).to eq(template)
    end

    it "project-level overrides account-level by name" do
      create(:pr_template, account: account, name: "standard", body: "old body")
      project_tmpl = create(:pr_template, account: account, project: project, name: "standard", body: "new body")

      result = described_class.resolve(project: project, user: user)

      expect(result).to eq(project_tmpl)
    end

    it "user-level overrides account-level by name" do
      create(:pr_template, account: account, name: "standard", body: "old body")
      user_tmpl = create(:pr_template, account: account, user: user, name: "standard", body: "user body")

      result = described_class.resolve(project: project, user: user)

      expect(result).to eq(user_tmpl)
    end

    it "project-level overrides user-level by name" do
      create(:pr_template, account: account, user: user, name: "standard", body: "user body")
      project_tmpl = create(:pr_template, account: account, project: project, name: "standard", body: "project body")

      result = described_class.resolve(project: project, user: user)

      expect(result).to eq(project_tmpl)
    end

    it "returns nil when no templates exist" do
      result = described_class.resolve(project: project, user: user)

      expect(result).to be_nil
    end

    it "filters by pr_type" do
      create(:pr_template, account: account, name: "standard", pr_type: "default")
      feature_tmpl = create(:pr_template, account: account, name: "feature-tmpl", pr_type: "feature")

      result = described_class.resolve(project: project, user: user, pr_type: "feature")

      expect(result).to eq(feature_tmpl)
    end

    it "excludes disabled templates" do
      create(:pr_template, account: account, name: "standard", enabled: false)

      result = described_class.resolve(project: project, user: user)

      expect(result).to be_nil
    end

    it "allows a disabled project override to suppress an account-level template" do
      create(:pr_template, account: account, name: "standard", enabled: true)
      create(:pr_template, account: account, project: project, name: "standard", enabled: false)

      result = described_class.resolve(project: project, user: user)

      expect(result).to be_nil
    end

    it "returns the template with lowest position" do
      create(:pr_template, account: account, name: "b-template", position: 1)
      first = create(:pr_template, account: account, name: "a-template", position: 0)

      result = described_class.resolve(project: project, user: user)

      expect(result).to eq(first)
    end

    it "works without a user" do
      template = create(:pr_template, account: account, name: "standard")

      result = described_class.resolve(project: project)

      expect(result).to eq(template)
    end

    it "ignores user from a different account" do
      other_account = create(:account)
      other_user = create(:user, account: other_account)
      create(:pr_template, account: other_account, user: other_user, name: "standard", body: "other")
      account_tmpl = create(:pr_template, account: account, name: "standard")

      result = described_class.resolve(project: project, user: other_user)

      expect(result).to eq(account_tmpl)
    end
  end

  describe "#render" do
    it "replaces variable placeholders with values" do
      template = build(:pr_template, body: "## Summary\n\n{{description}}\n\nCloses {{issue_url}}")

      result = template.render(
        "description" => "Added auth middleware",
        "issue_url" => "#42"
      )

      expect(result).to eq("## Summary\n\nAdded auth middleware\n\nCloses #42")
    end

    it "replaces multiple different variables" do
      template = build(:pr_template, body: "Branch: {{branch_name}}\nIssue: {{issue_title}} ({{issue_number}})")

      result = template.render(
        "branch_name" => "fix/auth-bug",
        "issue_title" => "Fix login",
        "issue_number" => "42"
      )

      expect(result).to eq("Branch: fix/auth-bug\nIssue: Fix login (42)")
    end

    it "leaves unmatched placeholders as-is" do
      template = build(:pr_template, body: "{{description}} and {{unknown}}")

      result = template.render("description" => "hello")

      expect(result).to eq("hello and {{unknown}}")
    end

    it "handles empty variables" do
      template = build(:pr_template, body: "## Summary\n\n{{description}}")

      result = template.render("description" => "")

      expect(result).to eq("## Summary\n\n")
    end
  end

  describe "callbacks" do
    it "sets account from project on validation" do
      project = create(:project)
      template = build(:pr_template, project: project, account: nil, name: "standard")

      template.valid?

      expect(template.account).to eq(project.account)
    end

    it "sets account from user on validation" do
      user = create(:user)
      template = build(:pr_template, user: user, project: nil, account: nil, name: "standard")

      template.valid?

      expect(template.account).to eq(user.account)
    end
  end
end
