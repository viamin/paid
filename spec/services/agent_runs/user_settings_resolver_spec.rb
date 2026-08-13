# frozen_string_literal: true

require "rails_helper"

RSpec.describe AgentRuns::UserSettingsResolver do
  describe ".call" do
    it "prefers project.created_by settings when present" do
      project = create(:project)

      result = described_class.call(project: project)

      expect(result).to eq(project.created_by.settings)
    end

    it "falls back to account owner membership when project has no creator" do
      account = create(:account)
      owner = create(:user, account: account)
      owner.account_memberships.find_by(account: account)&.update!(role: :owner)
      token = create(:github_token, :without_creator, account: account)
      project = create(:project, :without_creator, account: account, github_token: token)

      result = described_class.call(project: project)

      expect(result).to eq(owner.settings)
    end

    it "falls back to the first account user when no owner membership exists" do
      account = create(:account)
      first_user = create(:user, account: account)
      create(:user, account: account)
      token = create(:github_token, :without_creator, account: account)
      project = create(:project, :without_creator, account: account, github_token: token)

      result = described_class.call(project: project)

      expect(result).to eq(first_user.settings)
    end

    it "raises MissingUserError in strict mode when no users exist" do
      account = create(:account)
      token = create(:github_token, :without_creator, account: account)
      project = create(:project, :without_creator, account: account, github_token: token)

      account.users.destroy_all

      expect {
        described_class.call(project: project, strict: true)
      }.to raise_error(AgentRuns::UserSettingsResolver::MissingUserError)
    end

    it "returns nil in non-strict mode when no users exist" do
      account = create(:account)
      token = create(:github_token, :without_creator, account: account)
      project = create(:project, :without_creator, account: account, github_token: token)

      account.users.destroy_all

      expect(described_class.call(project: project, strict: false)).to be_nil
    end
  end
end
