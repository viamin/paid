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

  describe "inbox-driven returns" do
    let(:inbox_return) { "/inbox?kind=change_intent_draft&project_id=#{project.id}" }

    # @spec CHANGE-INTENT-INBOX-001
    it "redirects to the inbox when the approve action is called from the Inbox" do
      allow(ChangeIntents::SyncKnowledgeArtifact).to receive(:call)

      post approve_project_change_intent_path(project, change_intent, return_to: inbox_return)

      expect(response).to redirect_to(inbox_return)
      expect(change_intent.reload.status).to eq("active")
    end

    # @spec CHANGE-INTENT-INBOX-001
    it "redirects to the inbox when the discard action is called from the Inbox" do
      post discard_project_change_intent_path(project, change_intent, return_to: inbox_return)

      expect(response).to redirect_to(inbox_return)
      expect(ChangeIntent.where(id: change_intent.id)).to be_empty
    end

    # @spec CHANGE-INTENT-INBOX-001
    it "ignores an external return_to on approve and falls back to the project page" do
      allow(ChangeIntents::SyncKnowledgeArtifact).to receive(:call)

      post approve_project_change_intent_path(project, change_intent,
        return_to: "https://evil.example.com/inbox")

      expect(response).to redirect_to(project_path(project))
    end

    # @spec CHANGE-INTENT-INBOX-001
    it "ignores an external return_to on discard and falls back to the project page" do
      post discard_project_change_intent_path(project, change_intent,
        return_to: "//evil.example.com/inbox")

      expect(response).to redirect_to(project_path(project))
    end
  end

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

    # @spec CHANGE-INTENT-INBOX-001
    it "falls back to the change-intent page when an external return_to is supplied on the invalid-transition rescue branch" do
      change_intent.update!(status: "active")

      post discard_project_change_intent_path(project, change_intent,
        return_to: "https://evil.example.com/inbox")

      expect(response).to redirect_to(project_change_intent_path(project, change_intent))
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

    # @spec CHANGE-INTENT-INBOX-001
    it "forbids a viewer from requesting changes" do
      viewer = create(:user, account: account)
      viewer.add_role(:viewer, account)
      sign_in viewer

      post request_changes_project_change_intent_path(project, change_intent),
        params: { reason: "Reword the title." }

      expect(response).to redirect_to(root_path)
      expect(change_intent.reload.status).to eq("draft")
    end
  end

  # @spec CHANGE-INTENT-INBOX-001
  describe "POST /projects/:project_id/change_intents/:id/request_changes" do
    let(:inbox_return) { "/inbox?kind=change_intent_draft&project_id=#{project.id}" }

    it "stamps requested_changes_at and reason, then redirects back to the Inbox" do
      post request_changes_project_change_intent_path(project, change_intent, return_to: inbox_return),
        params: { reason: "Reword the title." }

      expect(response).to redirect_to(inbox_return)
      expect(change_intent.reload).to have_attributes(
        status: "requested_changes",
        requested_changes_reason: "Reword the title."
      )
      expect(change_intent.requested_changes_at).to be_present
    end

    it "tolerates a blank reason by storing nil and still redirecting" do
      post request_changes_project_change_intent_path(project, change_intent, return_to: inbox_return),
        params: { reason: "   " }

      expect(response).to redirect_to(inbox_return)
      expect(change_intent.reload).to have_attributes(
        status: "requested_changes",
        requested_changes_reason: nil
      )
    end

    it "redirects back to the project when no inbox return target is provided" do
      post request_changes_project_change_intent_path(project, change_intent),
        params: { reason: "Tighten the constraints." }

      expect(response).to redirect_to(project_path(project))
    end

    it "redirects gracefully when the record is no longer in a pending-review state" do
      change_intent.update!(status: "active")

      post request_changes_project_change_intent_path(project, change_intent, return_to: inbox_return),
        params: { reason: "Too late." }

      expect(response).to redirect_to(inbox_return)
    end

    # @spec CHANGE-INTENT-INBOX-001
    it "falls back to the project page when return_to points off-host" do
      post request_changes_project_change_intent_path(project, change_intent,
        return_to: "https://evil.example/phish"),
        params: { reason: "Reason" }

      expect(response).to redirect_to(project_path(project))
    end

    # @spec CHANGE-INTENT-INBOX-001
    it "falls back to the project page for a protocol-relative return_to" do
      post request_changes_project_change_intent_path(project, change_intent,
        return_to: "//evil.example/phish"),
        params: { reason: "Reason" }

      expect(response).to redirect_to(project_path(project))
    end

    # @spec CHANGE-INTENT-INBOX-001
    it "falls back to the project page when return_to is not inbox-scoped" do
      post request_changes_project_change_intent_path(project, change_intent,
        return_to: "/projects/some-other-project/edit"),
        params: { reason: "Reason" }

      expect(response).to redirect_to(project_path(project))
    end

    # @spec CHANGE-INTENT-INBOX-001
    it "falls back to the change-intent page on the rescue branch when return_to is external" do
      change_intent.update!(status: "active")

      post request_changes_project_change_intent_path(project, change_intent,
        return_to: "https://evil.example.com/inbox"),
        params: { reason: "Too late." }

      expect(response).to redirect_to(project_change_intent_path(project, change_intent))
    end
  end

  # @spec CHANGE-INTENT-INBOX-001
  describe "open-redirect protection" do
    before { allow(ChangeIntents::SyncKnowledgeArtifact).to receive(:call) }

    it "ignores an off-host return_to on approve and falls back to the project" do
      post approve_project_change_intent_path(project, change_intent,
        return_to: "https://evil.example/phish")

      expect(response).to redirect_to(project_path(project))
    end

    it "ignores a protocol-relative return_to on approve and falls back to the project" do
      post approve_project_change_intent_path(project, change_intent,
        return_to: "//evil.example/phish")

      expect(response).to redirect_to(project_path(project))
    end

    it "ignores an off-host return_to on discard and falls back to the project" do
      post discard_project_change_intent_path(project, change_intent,
        return_to: "https://evil.example/phish")

      expect(response).to redirect_to(project_path(project))
    end

    it "falls back to the change-intent show page for invalid transitions with an off-host return_to" do
      change_intent.update!(status: "active")

      post discard_project_change_intent_path(project, change_intent,
        return_to: "https://evil.example/phish")

      expect(response).to redirect_to(project_change_intent_path(project, change_intent))
    end
  end

  # @spec CHANGE-INTENT-INBOX-001
  describe "return_to URL sanitization" do
    it "falls back to the project page when return_to is an absolute URL" do
      allow(ChangeIntents::SyncKnowledgeArtifact).to receive(:call)

      post discard_project_change_intent_path(project, change_intent, return_to: "https://evil.example/phish")

      expect(response).to redirect_to(project_path(project))
    end

    it "falls back to the project page when return_to is a protocol-relative URL" do
      post discard_project_change_intent_path(project, change_intent, return_to: "//evil.example/phish")

      expect(response).to redirect_to(project_path(project))
    end

    it "falls back to the project page when return_to is a javascript: URL" do
      post discard_project_change_intent_path(project, change_intent, return_to: "javascript:alert(1)")

      expect(response).to redirect_to(project_path(project))
    end

    it "falls back to the project page when return_to is not inbox-scoped" do
      post discard_project_change_intent_path(project, change_intent, return_to: "/projects/other")

      expect(response).to redirect_to(project_path(project))
    end

    it "falls back to the project page when return_to is a malformed URI" do
      post discard_project_change_intent_path(project, change_intent, return_to: '/\\evil.example/inbox')

      expect(response).to redirect_to(project_path(project))
    end

    it "falls back to the change_intent show page on invalid transition when return_to is unsafe" do
      change_intent.update!(status: "active")

      post discard_project_change_intent_path(project, change_intent, return_to: "https://evil.example/phish")

      expect(response).to redirect_to(project_change_intent_path(project, change_intent))
    end
  end
end
