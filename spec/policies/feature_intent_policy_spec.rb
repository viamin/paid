# frozen_string_literal: true

require "rails_helper"

# @spec FEATURE-APPROVAL-012
RSpec.describe FeatureIntentPolicy do
  describe "#approve?" do
    it "permits any account member of the feature's project" do
      account = create(:account)
      create(:user, account: account) # absorb the auto-owner role
      member = create(:user, :member, account: account)
      project = create(:project, account: account)
      feature_intent = create(:feature_intent, project: project)

      expect(described_class.new(member, feature_intent)).to be_approve
    end

    it "permits an account viewer with an explicit project role" do
      account = create(:account)
      create(:user, account: account) # absorb the auto-owner role
      project = create(:project, account: account)
      feature_intent = create(:feature_intent, project: project)
      viewer_with_project_role = create(:user, :viewer, account: account)
      viewer_with_project_role.add_role(:project_member, project)

      expect(described_class.new(viewer_with_project_role, feature_intent)).to be_approve
    end

    it "does not permit a user outside the account without a project role" do
      account = create(:account)
      create(:user, account: account) # absorb the auto-owner role
      project = create(:project, account: account)
      feature_intent = create(:feature_intent, project: project)
      other_account = create(:account)
      outsider = create(:user, account: other_account)

      expect(described_class.new(outsider, feature_intent)).not_to be_approve
    end

    it "does not permit an account viewer without a project role" do
      account = create(:account)
      create(:user, account: account) # absorb the auto-owner role
      viewer = create(:user, :viewer, account: account)
      project = create(:project, account: account)
      feature_intent = create(:feature_intent, project: project)

      expect(described_class.new(viewer, feature_intent)).not_to be_approve
    end
  end

  describe "Scope" do
    it "resolves only feature intents whose project is visible to the user" do
      account = create(:account)
      user = create(:user, account: account)
      project = create(:project, account: account)
      own_feature_intent = create(:feature_intent, project: project)

      other_account = create(:account)
      other_project = create(:project, account: other_account)
      create(:feature_intent, project: other_project)

      scope = described_class::Scope.new(user, FeatureIntent).resolve

      expect(scope).to contain_exactly(own_feature_intent)
    end
  end
end
