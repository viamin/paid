# frozen_string_literal: true

require "rails_helper"

# @spec CHANGE-INTENT-004
RSpec.describe "Projects::ChangeIntents" do
  let(:account) { create(:account) }
  let(:owner) { create(:user, :owner, account:) }
  let(:project) { create(:project, account: account, created_by: owner) }
  let(:issue) { create(:issue, :in_progress, project: project, github_number: 7) }
  let!(:change_intent) do
    create(:change_intent, :draft, project: project, issue: issue, chat_session: nil,
                                   title: "Sliding window over token bucket",
                                   intent: "Smooth per-user limiting.",
                                   constraints: "Use Redis.",
                                   decisions_made: "Rejected token bucket.")
  end

  before { sign_in owner }

  describe "GET /projects/:project_id/change_intents/:id" do
    it "renders the draft with its content and approve/discard path" do
      get project_change_intent_path(project, change_intent)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Sliding window over token bucket")
      expect(response.body).to include("Smooth per-user limiting.")
      expect(response.body).to include("Use Redis.")
      expect(response.body).to include("Rejected token bucket.")
      expect(response.body).to include("Approve")
      expect(response.body).to include("Discard")
    end

    it "does not expose actions to a viewer without update access" do
      viewer = create(:user, account: account)
      viewer.add_role(:viewer, account)
      sign_in viewer

      get project_change_intent_path(project, change_intent)

      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include('value="Approve"')
    end
  end

  describe "POST /projects/:project_id/change_intents/:id/approve" do
    before { allow(ChangeIntents::SyncKnowledgeArtifact).to receive(:call) }

    it "activates the draft and indexes it into the knowledge pipeline" do
      post approve_project_change_intent_path(project, change_intent)

      expect(change_intent.reload.status).to eq("active")
      expect(ChangeIntents::SyncKnowledgeArtifact).to have_received(:call).with(change_intent: change_intent)
      expect(response).to redirect_to(project_path(project))
      follow_redirect!
      expect(response.body).to include("approved and added to the knowledge base")
    end
  end

  describe "POST /projects/:project_id/change_intents/:id/discard" do
    it "removes the draft" do
      post discard_project_change_intent_path(project, change_intent)

      expect(ChangeIntent.where(id: change_intent.id)).to be_empty
      expect(response).to redirect_to(project_path(project))
      follow_redirect!
      expect(response.body).to include("discarded")
    end

    it "redirects gracefully when the record is no longer a draft" do
      change_intent.update!(status: "active")

      post discard_project_change_intent_path(project, change_intent)

      expect(response).to redirect_to(project_change_intent_path(project, change_intent))
      follow_redirect!
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("cannot discard from active")
    end
  end

  describe "authorization" do
    it "forbids a viewer from approving" do
      viewer = create(:user, account: account)
      viewer.add_role(:viewer, account)
      sign_in viewer

      post approve_project_change_intent_path(project, change_intent)

      expect(response).to redirect_to(root_path)
      expect(change_intent.reload.status).to eq("draft")
    end
  end
end
