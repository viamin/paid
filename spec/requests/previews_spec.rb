# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Previews" do
  let(:account) { create(:account) }
  let(:project) { create(:project, account: account) }
  let!(:preview_session) do
    create(:preview_session, project: project, status: "active",
      branch_name: "feature/widget", token: "iframe-token")
  end

  describe "GET /previews/:id" do
    context "when the user is a project member" do
      let(:user) { create(:user, :viewer, account: account) }

      before do
        create(:project_membership, project: project, user: user, role: :member)
        sign_in user
      end

      it "renders the iframe wrapper page" do
        get preview_session_path(preview_session)

        expect(response).to have_http_status(:ok)
        expect(response.body).to include("<iframe")
        expect(response.body).to include("/previews/iframe-token/")
      end

      it "displays preview metadata" do
        get preview_session_path(preview_session)

        expect(response.body).to include("Live preview")
        expect(response.body).to include("feature/widget")
        expect(response.body).to include("active")
      end

      it "renders the stop control" do
        get preview_session_path(preview_session)

        expect(response.body).to include("Stop preview")
      end
    end

    context "when the user is an account admin without project membership" do
      let(:user) { create(:user, :admin, account: account) }

      before { sign_in user }

      it "renders the iframe wrapper page" do
        get preview_session_path(preview_session)

        expect(response).to have_http_status(:ok)
        expect(response.body).to include("/previews/iframe-token/")
      end
    end

    context "when the user is an account member without project membership" do
      let(:user) { create(:user, :member, account: account) }

      before { sign_in user }

      it "does not reveal the session and redirects" do
        get preview_session_path(preview_session)

        expect(response).not_to have_http_status(:ok)
        expect(response.body).not_to include("iframe-token")
      end
    end

    context "when the user is not a member of the account" do
      let(:other_account) { create(:account) }
      let(:user) { create(:user, :owner, account: other_account) }

      before { sign_in user }

      it "does not reveal the session and redirects" do
        get preview_session_path(preview_session)

        expect(response).not_to have_http_status(:ok)
        expect(response.body).not_to include("iframe-token")
      end
    end

    context "when the user is not authenticated" do
      it "redirects to the sign-in page" do
        get preview_session_path(preview_session)

        expect(response).to redirect_to(new_user_session_path)
      end
    end

    context "when the session does not exist for the viewer" do
      let(:user) { create(:user, :member, account: account) }

      before { sign_in user }

      it "redirects without revealing existence" do
        get preview_session_path(id: 999_999_999)

        expect(response).to redirect_to(root_path)
      end
    end
  end

  describe "POST /projects/:project_id/preview_sessions/:id/stop" do
    let(:user) { create(:user, :admin, account: account) }

    before { sign_in user }

    it "marks the preview as stopped and redirects to the project" do
      post stop_project_preview_session_path(project, preview_session)

      expect(preview_session.reload.status).to eq("stopped")
      expect(response).to redirect_to(project_path(project))
    end

    it "does not allow a non-admin member to stop" do
      viewer = create(:user, :member, account: account)
      sign_out user
      sign_in viewer

      post stop_project_preview_session_path(project, preview_session)

      expect(preview_session.reload.status).to eq("active")
    end
  end
end
