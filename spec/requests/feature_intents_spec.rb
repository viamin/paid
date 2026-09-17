# frozen_string_literal: true

require "rails_helper"

# @spec FEATURE-APPROVAL-009 @spec FEATURE-APPROVAL-010 @spec FEATURE-APPROVAL-012
RSpec.describe "Feature intents" do
  let(:owner) { create(:user, :owner) }
  let(:project) { create(:project, account: owner.account) }

  before { sign_in owner }

  describe "POST /feature_intents/:id/approve" do
    it "approves a ready feature intent and redirects to the inbox" do
      feature_intent = create(:feature_intent, :ready_for_approval, project: project)

      post approve_feature_intent_path(feature_intent)

      expect(response).to redirect_to(inbox_path(kind: Inbox::Queue::FEATURE_DECISION_KIND))
      expect(flash[:notice]).to eq("Feature approved.")
      expect(feature_intent.reload.status).to eq("approved_waiting_for_merge")
      expect(feature_intent.approved_by).to eq(owner)
    end

    it "rejects a viewer who can see the project but cannot mutate it" do
      viewer = create(:user, :viewer, account: owner.account)
      feature_intent = create(:feature_intent, :ready_for_approval, project: project)
      sign_out owner
      sign_in viewer

      post approve_feature_intent_path(feature_intent)

      expect(response).to redirect_to(root_path)
      expect(flash[:alert]).to include("not authorized")
      expect(feature_intent.reload.status).not_to eq("approved_waiting_for_merge")
    end

    it "does not allow approving a feature intent outside the user's account" do
      other_account = create(:account)
      hidden_project = create(:project, account: other_account)
      hidden_feature_intent = create(:feature_intent, :ready_for_approval, project: hidden_project)

      post approve_feature_intent_path(hidden_feature_intent)

      expect(response).to have_http_status(:not_found)
    end

    it "redirects back to the entry with an explanation when the feature intent is not ready" do
      feature_intent = create(:feature_intent, :ready_for_approval, project: project)
      create(:feature_intent_decision, feature_intent: feature_intent, kind: "question")

      post approve_feature_intent_path(feature_intent)

      expect(response).to redirect_to(inbox_entry_path("#{Inbox::Queue::FEATURE_DECISION_KIND}:#{feature_intent.id}"))
      expect(flash[:alert]).to include("Not ready to approve")
      expect(feature_intent.reload.status).not_to eq("approved_waiting_for_merge")
    end

    it "permits an account viewer with an explicit project role to approve" do
      viewer_with_project_role = create(:user, :viewer, account: owner.account)
      viewer_with_project_role.add_role(:project_member, project)
      feature_intent = create(:feature_intent, :ready_for_approval, project: project)
      sign_out owner
      sign_in viewer_with_project_role

      post approve_feature_intent_path(feature_intent)

      expect(feature_intent.reload.status).to eq("approved_waiting_for_merge")
      expect(feature_intent.approved_by).to eq(viewer_with_project_role)
    end

    it "redirects with a not-ready alert when the feature status is not approvable" do
      feature_intent = create(:feature_intent, :ready_for_approval, project: project, status: "discovering",
        criteria_clarity_state: "clear")

      post approve_feature_intent_path(feature_intent)

      expect(response).to redirect_to(inbox_entry_path("#{Inbox::Queue::FEATURE_DECISION_KIND}:#{feature_intent.id}"))
      expect(flash[:alert]).to include("Not ready to approve", "discovering")
      expect(feature_intent.reload.status).to eq("discovering")
    end

    it "gracefully redirects when the lifecycle transition rejects the approval mid-action" do
      feature_intent = create(:feature_intent, :ready_for_approval, project: project)
      feature_intent.update!(status: "released")
      allow(FeatureIntents::MarkApproved).to receive(:call).and_raise(FeatureIntent::InvalidTransitionError, "cannot approve a released feature intent")

      post approve_feature_intent_path(feature_intent)

      expect(response).to redirect_to(inbox_entry_path("#{Inbox::Queue::FEATURE_DECISION_KIND}:#{feature_intent.id}"))
      expect(flash[:alert]).to include("Not ready to approve", "released")
    end
  end
end
