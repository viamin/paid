# frozen_string_literal: true

require "rails_helper"

RSpec.describe PreCommitRequirement do
  describe "associations" do
    it { is_expected.to belong_to(:account) }
    it { is_expected.to belong_to(:project).optional }
    it { is_expected.to belong_to(:user).optional }
  end

  describe "validations" do
    subject { build(:pre_commit_requirement) }

    it { is_expected.to validate_presence_of(:name) }
    it { is_expected.to validate_length_of(:name).is_at_most(255) }
    it { is_expected.to validate_presence_of(:command) }
    it { is_expected.to validate_presence_of(:check_type) }
    it { is_expected.to validate_inclusion_of(:check_type).in_array(described_class::CHECK_TYPES) }
    it { is_expected.to validate_presence_of(:failure_behavior) }
    it { is_expected.to validate_inclusion_of(:failure_behavior).in_array(described_class::FAILURE_BEHAVIORS) }
    it { is_expected.to validate_numericality_of(:position).only_integer.is_greater_than_or_equal_to(0) }

    it "validates uniqueness of name scoped to account, project, and user" do
      account = create(:account)
      create(:pre_commit_requirement, account: account, name: "lint")
      duplicate = build(:pre_commit_requirement, account: account, name: "lint")

      expect(duplicate).not_to be_valid
      expect(duplicate.errors[:name]).to include("has already been taken")
    end

    it "allows same name in different projects" do
      account = create(:account)
      project1 = create(:project, account: account)
      project2 = create(:project, account: account)

      create(:pre_commit_requirement, account: account, project: project1, name: "lint")
      req = build(:pre_commit_requirement, account: account, project: project2, name: "lint")

      expect(req).to be_valid
    end

    it "validates project belongs to account" do
      account1 = create(:account)
      account2 = create(:account)
      project = create(:project, account: account2)

      req = build(:pre_commit_requirement, account: account1, project: project, name: "lint")
      req.valid?

      expect(req.errors[:project]).to include("must belong to the same account")
    end

    it "validates user belongs to account" do
      account1 = create(:account)
      account2 = create(:account)
      user = create(:user, account: account2)

      req = build(:pre_commit_requirement, account: account1, user: user, name: "lint")
      req.valid?

      expect(req.errors[:user]).to include("must belong to the same account")
    end

    it "validates fix_command requires auto_fix failure behavior" do
      req = build(:pre_commit_requirement, failure_behavior: "block", fix_command: "bin/lint -a")
      req.valid?

      expect(req.errors[:fix_command]).to include("can only be set when failure behavior is auto_fix")
    end

    it "allows fix_command with auto_fix failure behavior" do
      req = build(:pre_commit_requirement, :with_auto_fix)
      expect(req).to be_valid
    end

    it "rejects both project and user being set" do
      account = create(:account)
      project = create(:project, account: account)
      user = create(:user, account: account)

      req = build(:pre_commit_requirement, account: account, project: project, user: user)
      req.valid?

      expect(req.errors[:base]).to include("cannot be scoped to both a project and a user")
    end
  end

  describe "scopes" do
    let(:account) { create(:account) }
    let(:project) { create(:project, account: account) }
    let(:user) { create(:user, account: account) }

    describe ".enabled" do
      it "returns only enabled requirements" do
        enabled = create(:pre_commit_requirement, account: account, enabled: true)
        create(:pre_commit_requirement, account: account, enabled: false)

        expect(described_class.enabled).to eq([ enabled ])
      end
    end

    describe ".ordered" do
      it "orders by position then name" do
        c = create(:pre_commit_requirement, account: account, name: "c-check", position: 0)
        a = create(:pre_commit_requirement, account: account, name: "a-check", position: 1)
        b = create(:pre_commit_requirement, account: account, name: "b-check", position: 0)

        expect(described_class.ordered).to eq([ b, c, a ])
      end
    end

    describe ".for_account" do
      it "returns account-level requirements" do
        account_req = create(:pre_commit_requirement, account: account)
        create(:pre_commit_requirement, account: account, project: project)

        expect(described_class.for_account(account)).to eq([ account_req ])
      end
    end

    describe ".for_project" do
      it "returns project-level requirements" do
        create(:pre_commit_requirement, account: account)
        project_req = create(:pre_commit_requirement, account: account, project: project)

        expect(described_class.for_project(project)).to eq([ project_req ])
      end
    end

    describe ".for_user" do
      it "returns user-level requirements" do
        create(:pre_commit_requirement, account: account)
        user_req = create(:pre_commit_requirement, account: account, user: user)

        expect(described_class.for_user(user)).to eq([ user_req ])
      end
    end
  end

  describe "#account_level?" do
    it "returns true when no project or user" do
      req = build(:pre_commit_requirement)
      expect(req).to be_account_level
    end

    it "returns false when project is set" do
      project = create(:project)
      req = build(:pre_commit_requirement, account: project.account, project: project)
      expect(req).not_to be_account_level
    end
  end

  describe "#project_level?" do
    it "returns true when project is set" do
      project = create(:project)
      req = build(:pre_commit_requirement, account: project.account, project: project)
      expect(req).to be_project_level
    end
  end

  describe "#user_level?" do
    it "returns true when user is set and no project" do
      user = create(:user)
      req = build(:pre_commit_requirement, account: user.account, user: user)
      expect(req).to be_user_level
    end
  end

  describe "#auto_fix?" do
    it "returns true for auto_fix failure behavior" do
      req = build(:pre_commit_requirement, :with_auto_fix)
      expect(req).to be_auto_fix
    end

    it "returns false for block failure behavior" do
      req = build(:pre_commit_requirement, failure_behavior: "block")
      expect(req).not_to be_auto_fix
    end
  end

  describe "#blocking?" do
    it "returns true for block failure behavior" do
      req = build(:pre_commit_requirement, failure_behavior: "block")
      expect(req).to be_blocking
    end

    it "returns true for auto_fix failure behavior" do
      req = build(:pre_commit_requirement, :with_auto_fix)
      expect(req).to be_blocking
    end

    it "returns false for warn failure behavior" do
      req = build(:pre_commit_requirement, :warn_only)
      expect(req).not_to be_blocking
    end
  end

  describe ".resolve" do
    let(:account) { create(:account) }
    let(:user) { create(:user, account: account) }
    let(:project) { create(:project, account: account) }

    it "returns account-level requirements when no overrides" do
      req = create(:pre_commit_requirement, account: account, name: "lint")

      result = described_class.resolve(project: project, user: user)

      expect(result.map(&:id)).to eq([ req.id ])
    end

    it "project-level overrides account-level by name" do
      create(:pre_commit_requirement, account: account, name: "lint", command: "old-lint")
      project_req = create(:pre_commit_requirement, account: account, project: project, name: "lint", command: "new-lint")

      result = described_class.resolve(project: project, user: user)

      expect(result.map(&:id)).to eq([ project_req.id ])
    end

    it "user-level overrides account-level by name" do
      create(:pre_commit_requirement, account: account, name: "lint", command: "old-lint")
      user_req = create(:pre_commit_requirement, account: account, user: user, name: "lint", command: "user-lint")

      result = described_class.resolve(project: project, user: user)

      expect(result.map(&:id)).to eq([ user_req.id ])
    end

    it "project-level overrides user-level by name" do
      create(:pre_commit_requirement, account: account, user: user, name: "lint", command: "user-lint")
      project_req = create(:pre_commit_requirement, account: account, project: project, name: "lint", command: "project-lint")

      result = described_class.resolve(project: project, user: user)

      expect(result.map(&:id)).to eq([ project_req.id ])
    end

    it "merges requirements with different names" do
      account_req = create(:pre_commit_requirement, account: account, name: "lint", position: 0)
      project_req = create(:pre_commit_requirement, account: account, project: project, name: "test", position: 1)

      result = described_class.resolve(project: project, user: user)

      expect(result.map(&:id)).to eq([ account_req.id, project_req.id ])
    end

    it "excludes disabled requirements" do
      create(:pre_commit_requirement, account: account, name: "lint", enabled: false)
      enabled_req = create(:pre_commit_requirement, account: account, name: "test", enabled: true)

      result = described_class.resolve(project: project, user: user)

      expect(result.map(&:id)).to eq([ enabled_req.id ])
    end

    it "sorts by position then name" do
      req_b = create(:pre_commit_requirement, account: account, name: "b-check", position: 0)
      req_a = create(:pre_commit_requirement, account: account, name: "a-check", position: 1)

      result = described_class.resolve(project: project)

      expect(result.map(&:id)).to eq([ req_b.id, req_a.id ])
    end

    it "works without a user" do
      req = create(:pre_commit_requirement, account: account, name: "lint")

      result = described_class.resolve(project: project)

      expect(result.map(&:id)).to eq([ req.id ])
    end

    it "ignores user from a different account" do
      other_account = create(:account)
      other_user = create(:user, account: other_account)
      create(:pre_commit_requirement, account: other_account, user: other_user, name: "lint", command: "other-lint")
      account_req = create(:pre_commit_requirement, account: account, name: "lint")

      result = described_class.resolve(project: project, user: other_user)

      expect(result.map(&:id)).to eq([ account_req.id ])
    end
  end

  describe "callbacks" do
    it "sets account from project on validation" do
      project = create(:project)
      req = build(:pre_commit_requirement, project: project, account: nil, name: "lint")

      req.valid?

      expect(req.account).to eq(project.account)
    end
  end
end
