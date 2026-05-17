# frozen_string_literal: true

require "rails_helper"

RSpec.describe Strategy do
  describe "associations" do
    it { is_expected.to belong_to(:account).optional }
    it { is_expected.to belong_to(:project).optional }
    it { is_expected.to belong_to(:current_version).class_name("StrategyVersion").optional }
    it { is_expected.to have_many(:strategy_versions).dependent(:destroy) }
  end

  describe "validations" do
    subject { build(:strategy, :global) }

    it { is_expected.to validate_presence_of(:slug) }
    it { is_expected.to validate_length_of(:slug).is_at_most(100) }
    it { is_expected.to validate_presence_of(:name) }
    it { is_expected.to validate_length_of(:name).is_at_most(255) }
    it { is_expected.to validate_presence_of(:decision_type) }
    it { is_expected.to validate_length_of(:decision_type).is_at_most(100) }
    it { is_expected.to validate_presence_of(:status) }
    it { is_expected.to validate_inclusion_of(:status).in_array(described_class::STATUSES) }

    it "validates slug format" do
      strategy = build(:strategy, :global, slug: "valid.slug-name_1")
      expect(strategy).to be_valid

      strategy = build(:strategy, :global, slug: "Invalid Slug!")
      expect(strategy).not_to be_valid
      expect(strategy.errors[:slug]).to be_present
    end

    it "validates slug uniqueness within scope" do
      create(:strategy, :global, slug: "issue.execution")

      duplicate = build(:strategy, :global, slug: "issue.execution")
      expect(duplicate).not_to be_valid
      expect(duplicate.errors[:slug]).to be_present
    end

    it "allows same slug at different scopes" do
      create(:strategy, :global, slug: "issue.execution")
      account_strategy = build(:strategy, :for_account, slug: "issue.execution")

      expect(account_strategy).to be_valid
    end

    it "auto-sets account from project when account is nil" do
      project = create(:project)
      strategy = build(:strategy, project: project, account: nil, slug: "test.strategy")

      expect(strategy).to be_valid
      expect(strategy.account).to eq(project.account)
    end

    it "validates project belongs to account" do
      account = create(:account)
      other_account = create(:account)
      project = create(:project, account: other_account)

      strategy = build(:strategy, account: account, project: project, slug: "test.strategy")
      expect(strategy).not_to be_valid
      expect(strategy.errors[:project]).to include("must belong to the same account")
    end

    it "requires selection_rules to be an object" do
      strategy = build(:strategy, :global, selection_rules: [])

      expect(strategy).not_to be_valid
      expect(strategy.errors[:selection_rules]).to include("must be an object")
    end

    it "requires current_version to belong to the strategy" do
      strategy = create(:strategy, :global)
      other_version = create(:strategy_version)
      strategy.current_version = other_version

      expect(strategy).not_to be_valid
      expect(strategy.errors[:current_version]).to include("must belong to this strategy")
    end

    it "rejects a non-active current_version" do
      strategy = create(:strategy, :global)
      draft_version = create(:strategy_version, strategy: strategy, promotion_state: "draft")
      strategy.current_version = draft_version

      expect(strategy).not_to be_valid
      expect(strategy.errors[:current_version]).to include("must be active before it can become current")
    end

    it "rejects a retired current_version" do
      strategy = create(:strategy, :global)
      retired_version = create(:strategy_version, :retired, strategy: strategy)
      strategy.current_version = retired_version

      expect(strategy).not_to be_valid
      expect(strategy.errors[:current_version]).to include("must be active before it can become current")
    end
  end

  describe "scopes" do
    describe ".active" do
      it "returns only active strategies" do
        active = create(:strategy, :global, status: "active")
        archived = create(:strategy, :global, :archived)

        expect(described_class.active).to include(active)
        expect(described_class.active).not_to include(archived)
      end
    end

    describe ".global" do
      it "returns strategies without account or project" do
        global = create(:strategy, :global)
        account_strategy = create(:strategy, :for_account)

        expect(described_class.global).to include(global)
        expect(described_class.global).not_to include(account_strategy)
      end
    end

    describe ".for_account" do
      it "returns account-level strategies" do
        account = create(:account)
        account_strategy = create(:strategy, account: account, project: nil)
        create(:strategy, :global)

        expect(described_class.for_account(account)).to eq([ account_strategy ])
      end
    end

    describe ".for_project" do
      it "returns project-level strategies" do
        project = create(:project)
        project_strategy = create(:strategy, project: project)
        create(:strategy, :global)

        expect(described_class.for_project(project)).to eq([ project_strategy ])
      end
    end

    describe ".by_decision_type" do
      it "returns strategies for the given decision type" do
        selected = create(:strategy, :global, decision_type: "issue_execution")
        create(:strategy, :global, decision_type: "retry")

        expect(described_class.by_decision_type("issue_execution")).to eq([ selected ])
      end
    end
  end

  describe "instance methods" do
    describe "#global?" do
      it "returns true when no account or project" do
        expect(build(:strategy, :global).global?).to be true
      end
    end

    describe "#account_level?" do
      it "returns true when account present and no project" do
        expect(build(:strategy, :for_account).account_level?).to be true
      end
    end

    describe "#project_level?" do
      it "returns true when project present" do
        expect(build(:strategy, :for_project).project_level?).to be true
      end
    end

    describe "#create_version!" do
      it "creates a new version with an auto-incremented version number" do
        strategy = create(:strategy, :global)

        version1 = strategy.create_version!(content: { "mode" => "single" })
        version2 = strategy.create_version!(content: { "mode" => "parallel" })

        expect(version1.version).to eq(1)
        expect(version2.version).to eq(2)
      end

      it "ignores caller-supplied version keys to preserve auto-increment" do
        strategy = create(:strategy, :global)

        version = strategy.create_version!(content: { "mode" => "single" }, version: 99)

        expect(version.version).to eq(1)
      end
    end

    describe "#create_pending_version!" do
      it "creates a candidate version without promoting it" do
        strategy = create(:strategy, :global)

        version = strategy.create_pending_version!(content: { "mode" => "single" })

        expect(version.version).to eq(1)
        expect(version.promotion_state).to eq("candidate")
        expect(strategy.reload.current_version).to be_nil
      end

      it "ignores caller-supplied promotion state" do
        strategy = create(:strategy, :global)

        version = strategy.create_pending_version!(
          content: { "mode" => "single" },
          promotion_state: "active"
        )

        expect(version.promotion_state).to eq("candidate")
        expect(version).to be_pending_review
      end
    end

    describe "#pending_reviews" do
      it "returns candidate versions awaiting review" do
        strategy = create(:strategy, :global)
        candidate = create(:strategy_version, :candidate, strategy: strategy)
        create(:strategy_version, :rejected, strategy: strategy)

        expect(strategy.pending_reviews).to contain_exactly(candidate)
      end
    end
  end
end
