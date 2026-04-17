# frozen_string_literal: true

require "rails_helper"

RSpec.describe TrackerConfiguration do
  describe "validations" do
    it "is valid with valid attributes" do
      tracker_config = build(:tracker_configuration)

      expect(tracker_config).to be_valid
    end

    it "requires tracker_type" do
      tracker_config = build(:tracker_configuration, tracker_type: nil)

      expect(tracker_config).not_to be_valid
      expect(tracker_config.errors[:tracker_type]).to include("can't be blank")
    end

    it "rejects invalid tracker_type" do
      tracker_config = build(:tracker_configuration, tracker_type: "unknown")

      expect(tracker_config).not_to be_valid
      expect(tracker_config.errors[:tracker_type]).to include("is not included in the list")
    end

    it "accepts all valid tracker types" do
      described_class::TRACKER_TYPES.each do |tracker_type|
        tracker_config = build(:tracker_configuration, tracker_type: tracker_type)
        expect(tracker_config).to be_valid, "Expected #{tracker_type} to be valid"
      end
    end

    it "enforces one configuration per configurable" do
      account = create(:account)
      create(:tracker_configuration, configurable: account)

      duplicate = build(:tracker_configuration, configurable: account)

      expect(duplicate).not_to be_valid
      expect(duplicate.errors[:configurable_id]).to include("already has a tracker configuration")
    end

    it "allows different configurables to each have a configuration" do
      account = create(:account)
      user = create(:user, account: account)

      account_config = create(:tracker_configuration, configurable: account)
      user_config = build(:tracker_configuration, configurable: user, tracker_type: "jira")

      expect(account_config).to be_valid
      expect(user_config).to be_valid
    end

    it "validates credential belongs to same account" do
      account1 = create(:account)
      account2 = create(:account)
      credential = create(:integration_credential, :jira, account: account2)

      tracker_config = build(:tracker_configuration,
        configurable: account1,
        tracker_type: "jira",
        integration_credential: credential)

      expect(tracker_config).not_to be_valid
      expect(tracker_config.errors[:integration_credential]).to include("must belong to the same account")
    end

    it "validates credential is active" do
      account = create(:account)
      credential = create(:integration_credential, :jira, :revoked, account: account)

      tracker_config = build(:tracker_configuration,
        configurable: account,
        tracker_type: "jira",
        integration_credential: credential)

      expect(tracker_config).not_to be_valid
      expect(tracker_config.errors[:integration_credential]).to include("must be active (not revoked or expired)")
    end
  end

  describe "#account" do
    it "returns the account when configurable is an Account" do
      account = create(:account)
      tracker_config = build(:tracker_configuration, configurable: account)

      expect(tracker_config.account).to eq(account)
    end

    it "returns the user's account when configurable is a User" do
      user = create(:user)
      tracker_config = build(:tracker_configuration, configurable: user)

      expect(tracker_config.account).to eq(user.account)
    end

    it "returns the project's account when configurable is a Project" do
      project = create(:project)
      tracker_config = build(:tracker_configuration, :for_project, configurable: project)

      expect(tracker_config.account).to eq(project.account)
    end
  end

  describe "#adapter" do
    it "returns an adapter instance via the factory" do
      tracker_config = build(:tracker_configuration, tracker_type: "github_issues")

      adapter = tracker_config.adapter

      expect(adapter).to be_a(IssueTrackers::Adapters::GithubIssues)
    end
  end

  describe ".enabled" do
    it "only includes enabled configurations" do
      enabled = create(:tracker_configuration)
      create(:tracker_configuration, :for_user, :disabled,
        configurable: create(:user, account: enabled.account))

      expect(described_class.enabled).to contain_exactly(enabled)
    end
  end
end
