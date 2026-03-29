# frozen_string_literal: true

require "rails_helper"

RSpec.describe KnowledgeSearchPolicy do
  let(:account) { create(:account) }
  let(:github_token) { create(:github_token, account: account) }
  let(:project) { create(:project, account: account, github_token: github_token) }

  describe "#search?" do
    it "allows users in the same account" do
      user = create(:user, account: account)

      policy = described_class.new(user, project)
      expect(policy.search?).to be true
    end

    it "allows users with project-level roles from another account" do
      other_account = create(:account)
      user = create(:user, account: other_account)
      user.add_role(:project_member, project)

      policy = described_class.new(user, project)
      expect(policy.search?).to be true
    end

    it "denies users from other accounts without project roles" do
      other_account = create(:account)
      other_user = create(:user, account: other_account)

      policy = described_class.new(other_user, project)
      expect(policy.search?).to be false
    end

    it "denies unauthenticated users" do
      policy = described_class.new(nil, project)
      expect(policy.search?).to be false
    end
  end
end
