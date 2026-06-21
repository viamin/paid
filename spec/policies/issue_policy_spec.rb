# frozen_string_literal: true

require "rails_helper"

RSpec.describe IssuePolicy do
  describe "#toggle_pause?" do
    it "permits owner" do
      account = create(:account)
      owner = create(:user, account: account)
      project = create(:project, account: account, created_by: owner)
      issue = create(:issue, project: project)

      expect(described_class.new(owner, issue)).to be_toggle_pause
    end

    it "permits admin" do
      account = create(:account)
      create(:user, account: account) # absorb owner role
      admin = create(:user, :admin, account: account)
      issue = create(:issue, project: create(:project, account: account))

      expect(described_class.new(admin, issue)).to be_toggle_pause
    end

    it "does not permit member" do
      account = create(:account)
      create(:user, account: account) # absorb owner role
      member = create(:user, :member, account: account)
      issue = create(:issue, project: create(:project, account: account))

      expect(described_class.new(member, issue)).not_to be_toggle_pause
    end

    it "does not permit viewer" do
      account = create(:account)
      create(:user, account: account) # absorb owner role
      viewer = create(:user, :viewer, account: account)
      issue = create(:issue, project: create(:project, account: account))

      expect(described_class.new(viewer, issue)).not_to be_toggle_pause
    end

    it "does not permit users from a different account" do
      account = create(:account)
      create(:user, account: account)
      issue = create(:issue, project: create(:project, account: account))
      other_user = create(:user, account: create(:account))

      expect(described_class.new(other_user, issue)).not_to be_toggle_pause
    end

    it "does not permit anonymous users" do
      account = create(:account)
      issue = create(:issue, project: create(:project, account: account))

      expect(described_class.new(nil, issue)).not_to be_toggle_pause
    end
  end
end
