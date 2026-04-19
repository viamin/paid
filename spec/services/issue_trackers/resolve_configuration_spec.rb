# frozen_string_literal: true

require "rails_helper"

RSpec.describe IssueTrackers::ResolveConfiguration do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:project) { create(:project, account: account, created_by: user) }

  describe ".call" do
    context "with no configurations" do
      it "returns a default github_issues configuration" do
        result = described_class.call(project: project)

        expect(result.tracker_type).to eq("github_issues")
        expect(result.enabled).to be(true)
        expect(result).not_to be_persisted
      end
    end

    context "with account-level configuration" do
      it "returns the account configuration" do
        account_config = create(:tracker_configuration, :jira, configurable: account)

        result = described_class.call(project: project)

        expect(result).to eq(account_config)
      end
    end

    context "with user-level configuration" do
      it "overrides account configuration" do
        create(:tracker_configuration, :jira, configurable: account)
        user_config = create(:tracker_configuration, :linear, configurable: user)

        result = described_class.call(project: project, user: user)

        expect(result).to eq(user_config)
      end
    end

    context "with project-level configuration" do
      it "overrides both user and account configurations" do
        create(:tracker_configuration, :jira, configurable: account)
        create(:tracker_configuration, :linear, configurable: user)
        project_config = create(:tracker_configuration, :azure_devops, configurable: project)

        result = described_class.call(project: project, user: user)

        expect(result).to eq(project_config)
      end
    end

    context "with disabled configurations" do
      it "skips disabled project configuration and falls through" do
        account_config = create(:tracker_configuration, :jira, configurable: account)
        create(:tracker_configuration, :azure_devops, :disabled, configurable: project)

        result = described_class.call(project: project)

        expect(result).to eq(account_config)
      end

      it "skips disabled user configuration and falls through" do
        account_config = create(:tracker_configuration, :jira, configurable: account)
        create(:tracker_configuration, :linear, :disabled, configurable: user)

        result = described_class.call(project: project, user: user)

        expect(result).to eq(account_config)
      end

      it "returns default when all configurations are disabled" do
        create(:tracker_configuration, :jira, :disabled, configurable: account)

        result = described_class.call(project: project)

        expect(result.tracker_type).to eq("github_issues")
        expect(result).not_to be_persisted
      end
    end
  end
end
