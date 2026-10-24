# frozen_string_literal: true

require "rails_helper"

# @spec FEATURE-APPROVAL-009 @spec FEATURE-APPROVAL-010 @spec FEATURE-APPROVAL-012 @spec FEATURE-APPROVAL-020
RSpec.describe "Feature intents" do
  let(:owner) { create(:user, :owner) }
  let(:project) { create(:project, account: owner.account) }

  before { sign_in owner }

  describe "GET /feature_intents" do
    # @spec FEATURE-APPROVAL-020
    it "keeps background proposals and declined proposal history reachable outside the action Inbox" do
      discovering = create(:feature_intent, project: project, status: "discovering", criteria_clarity_state: "pending",
        title: "Background proposal")
      cancelled = create(:feature_intent, project: project, status: "cancelled", cancelled_by: owner,
        cancelled_at: 1.hour.ago, cancellation_reason: "superseded", title: "Declined proposal")

      get feature_intents_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(discovering.title, cancelled.title, "Declined proposals", "Reopen for discovery")
    end
  end

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

  describe "POST /feature_intents/:id/cancel" do
    it "declines a discovering duplicate without requiring approval readiness" do
      feature_intent = create(:feature_intent, project: project, status: "discovering", criteria_clarity_state: "pending")

      post cancel_feature_intent_path(feature_intent), params: {
        cancellation_reason: "already_handled",
        replacement_reference: "https://github.com/viamin/paid/pull/4430"
      }

      expect(response).to redirect_to(feature_intents_path)
      expect(flash[:notice]).to eq("Feature proposal declined. It remains available in proposal history.")
      expect(feature_intent.reload).to have_attributes(
        status: "cancelled",
        cancelled_by: owner,
        cancellation_reason: "already_handled",
        replacement_reference: "https://github.com/viamin/paid/pull/4430"
      )
    end

    it "redirects with a validation message when the cancellation reason is missing" do
      feature_intent = create(:feature_intent, project: project, status: "discovering", criteria_clarity_state: "pending")

      post cancel_feature_intent_path(feature_intent)

      expect(response).to redirect_to(feature_intents_path)
      expect(flash[:alert]).to eq("Select why this proposal is being declined.")
      expect(feature_intent.reload.status).to eq("discovering")
    end

    # @spec FEATURE-APPROVAL-020
    it "rejects a replacement reference outside http(s)" do
      feature_intent = create(:feature_intent, project: project, status: "discovering", criteria_clarity_state: "pending")

      post cancel_feature_intent_path(feature_intent), params: {
        cancellation_reason: "already_handled",
        replacement_reference: "javascript:alert(1)"
      }

      expect(response).to redirect_to(feature_intents_path)
      expect(flash[:alert]).to eq("Replacement reference must be an http(s) URL")
      expect(feature_intent.reload.status).to eq("discovering")
    end
  end

  describe "POST /feature_intents/:id/reopen" do
    # @spec FEATURE-APPROVAL-020
    it "reopens a declined feature for discovery without retaining cancellation metadata" do
      feature_intent = create(:feature_intent, project: project, status: "cancelled", cancelled_by: owner,
        cancelled_at: 1.hour.ago, cancellation_reason: "superseded", replacement_reference: "https://github.com/viamin/paid/pull/4430")

      post reopen_feature_intent_path(feature_intent)

      expect(response).to redirect_to(feature_intents_path)
      expect(feature_intent.reload).to have_attributes(
        status: "discovering",
        cancelled_by: nil,
        cancelled_at: nil,
        cancellation_reason: nil,
        replacement_reference: nil
      )
    end
  end

  describe "POST /feature_intents/:id/decisions/:decision_id/respond" do
    # @spec FACET-CONFIDENCE-019
    it "preserves an unrelated invalid-response draft after saving a response" do
      feature_intent = create(:feature_intent, :ready_for_approval, project: project)
      unsaved_decision = create(:feature_intent_decision, feature_intent: feature_intent)
      answered_decision = create(:feature_intent_decision, feature_intent: feature_intent)

      post respond_to_decision_feature_intent_path(feature_intent, decision_id: unsaved_decision), params: { answer: " " }
      post respond_to_decision_feature_intent_path(feature_intent, decision_id: answered_decision), params: { answer: "Use CSV exports only." }

      expect(response).to redirect_to(inbox_entry_path("#{Inbox::Queue::FEATURE_DECISION_KIND}:#{feature_intent.id}"))
      expect(session[:feature_decision_drafts]).to eq(feature_intent.id.to_s => { unsaved_decision.id.to_s => " " })
      expect(answered_decision.reload).to have_attributes(status: "resolved", answer: "Use CSV exports only.", resolved_by: owner)
    end

    # @spec FACET-CONFIDENCE-019
    it "keeps an unsaved draft through the redirect and later refreshes" do
      feature_intent = create(:feature_intent, :ready_for_approval, project: project)
      open_decision = create(:feature_intent_decision, feature_intent: feature_intent)
      resolved_decision = create(:feature_intent_decision, :resolved, feature_intent: feature_intent)

      post respond_to_decision_feature_intent_path(feature_intent, decision_id: open_decision), params: { answer: " " }
      follow_redirect!
      get inbox_entry_path("#{Inbox::Queue::FEATURE_DECISION_KIND}:#{feature_intent.id}")
      expect(session[:feature_decision_drafts]).to eq(feature_intent.id.to_s => { open_decision.id.to_s => " " })

      post respond_to_decision_feature_intent_path(feature_intent, decision_id: resolved_decision), params: { answer: "Apply to existing records too." }
      follow_redirect!
      get inbox_entry_path("#{Inbox::Queue::FEATURE_DECISION_KIND}:#{feature_intent.id}")

      expect(response).to have_http_status(:ok)
      expect(session[:feature_decision_drafts]).to eq(
        feature_intent.id.to_s => {
          open_decision.id.to_s => " ",
          resolved_decision.id.to_s => "Apply to existing records too."
        }
      )
    end

    # @spec FACET-CONFIDENCE-019
    it "rejects an oversized response without truncating it into a stale draft" do
      feature_intent = create(:feature_intent, :ready_for_approval, project: project)
      decision = create(:feature_intent_decision, :resolved, feature_intent: feature_intent)
      answer = "a" * (FeatureIntents::ResponseDrafts::MAX_ANSWER_CHARS + 1)

      post respond_to_decision_feature_intent_path(feature_intent, decision_id: decision), params: { answer: answer }

      expect(response).to redirect_to(inbox_entry_path("#{Inbox::Queue::FEATURE_DECISION_KIND}:#{feature_intent.id}"))
      expect(flash[:alert]).to eq("Responses must be #{FeatureIntents::ResponseDrafts::MAX_ANSWER_CHARS} characters or fewer.")
      expect(session[:feature_decision_drafts]).to be_nil
    end

    # @spec FACET-CONFIDENCE-019
    it "rejects a viewer who can see the project but cannot respond to its decisions" do
      viewer = create(:user, :viewer, account: owner.account)
      feature_intent = create(:feature_intent, :ready_for_approval, project: project)
      decision = create(:feature_intent_decision, feature_intent: feature_intent)
      sign_out owner
      sign_in viewer

      post respond_to_decision_feature_intent_path(feature_intent, decision_id: decision), params: { answer: "Use CSV exports only." }

      expect(response).to redirect_to(root_path)
      expect(flash[:alert]).to include("not authorized")
      expect(decision.reload).to have_attributes(status: "open", answer: nil)
    end

    # @spec FACET-CONFIDENCE-019
    it "does not allow responding to a decision outside the user's account" do
      other_account = create(:account)
      hidden_project = create(:project, account: other_account)
      hidden_feature_intent = create(:feature_intent, :ready_for_approval, project: hidden_project)
      hidden_decision = create(:feature_intent_decision, feature_intent: hidden_feature_intent)

      post respond_to_decision_feature_intent_path(hidden_feature_intent, decision_id: hidden_decision), params: { answer: "No." }

      expect(response).to have_http_status(:not_found)
      expect(hidden_decision.reload).to have_attributes(status: "open", answer: nil)
    end
  end
end
