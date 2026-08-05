# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Previews" do
  let(:account) { create(:account) }
  let(:project) { create(:project, account: account) }
  let!(:preview_session) do
    create(:preview_session, :ready, project: project,
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
        expect(response.body).to include("Ready")
      end

      it "hides the stop control from non-admin project members" do
        get preview_session_path(preview_session)

        # stop? requires an owner/admin account role; a plain project member
        # can view the preview but must not tear it down.
        expect(response.body).not_to include("Stop preview")
        expect(response.body).to include("Back to project")
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

      it "renders the stop control" do
        get preview_session_path(preview_session)

        expect(response.body).to include("Stop preview")
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

    context "with lifecycle states" do
      let(:user) { create(:user, :admin, account: account) }

      before { sign_in user }

      it "surfaces a provisioning state without an iframe" do
        session = create(:preview_session, :provisioning, project: project,
          branch_name: "feature/wip", tunnel_port: nil)

        get preview_session_path(session)

        expect(response).to have_http_status(:ok)
        expect(response.body).to include("Provisioning")
        expect(response.body).to include("Booting the container and installing dependencies")
        expect(response.body).not_to include("<iframe")
      end

      it "surfaces a failed state with the error message" do
        session = create(:preview_session, :failed, project: project,
          branch_name: "feature/broken", error_message: "Could not start the app server")

        get preview_session_path(session)

        expect(response).to have_http_status(:ok)
        expect(response.body).to include("Failed")
        expect(response.body).to include("Could not start the app server")
        expect(response.body).not_to include("<iframe")
      end

      it "surfaces a stopped state with guidance to start a new preview" do
        session = create(:preview_session, :stopped, project: project,
          branch_name: "feature/old")

        get preview_session_path(session)

        expect(response).to have_http_status(:ok)
        expect(response.body).to include("Stopped")
        expect(response.body).to include("Start a new preview")
        expect(response.body).not_to include("<iframe")
      end

      it "only renders the stop control for an active session" do
        active = create(:preview_session, :provisioning, project: project,
          branch_name: "feature/active", tunnel_port: nil)
        stopped = create(:preview_session, :stopped, project: project,
          branch_name: "feature/done")

        get preview_session_path(active)
        expect(response.body).to include("Stop preview")

        get preview_session_path(stopped)
        expect(response.body).not_to include("Stop preview")
      end
    end
  end

  describe "GET /previews/:token/*" do
    before do
      # The :ready factory defaults to a simulated container id; this block
      # exercises the real reverse-proxy path, so swap in a real container id.
      preview_session.update!(container_id: "container-real")
      stub_request(:get, "http://127.0.0.1:#{preview_session.tunnel_port}/")
        .to_return(status: 200, body: "proxied app")
    end

    context "when the user is a project member" do
      let(:user) { create(:user, :viewer, account: account) }

      before do
        create(:project_membership, project: project, user: user, role: :member)
        sign_in user
      end

      it "serves the proxied preview content" do
        get "#{preview_session.proxy_prefix}/"

        expect(response).to have_http_status(:ok)
        expect(response.body).to eq("proxied app")
      end

      it "looks up the preview session from the path token, not the query string" do
        other_session = create(
          :preview_session,
          :ready,
          project: project,
          branch_name: "feature/other",
          token: "query-token",
          container_id: "container-query"
        )
        path_token_request = stub_request(:get, "http://127.0.0.1:#{preview_session.tunnel_port}/?token=#{other_session.token}")
          .to_return(status: 200, body: "path token app")
        query_token_request = stub_request(:get, "http://127.0.0.1:#{other_session.tunnel_port}/?token=#{other_session.token}")
          .to_return(status: 200, body: "query token app")

        get "#{preview_session.proxy_prefix}/?token=#{other_session.token}"

        expect(response).to have_http_status(:ok)
        expect(response.body).to eq("path token app")
        expect(path_token_request).to have_been_made.once
        expect(query_token_request).not_to have_been_made
      end
    end

    context "when the user is not authenticated" do
      it "returns 404 to avoid revealing that the preview exists" do
        get "#{preview_session.proxy_prefix}/"

        expect(response).to have_http_status(:not_found)
      end
    end

    context "when the user is an account member without project membership" do
      let(:user) { create(:user, :member, account: account) }

      before { sign_in user }

      it "returns 404 to avoid revealing that the preview exists" do
        get "#{preview_session.proxy_prefix}/"

        expect(response).to have_http_status(:not_found)
      end
    end

    context "when the session is live but not yet proxiable" do
      let(:user) { create(:user, :viewer, account: account) }

      before do
        create(:project_membership, project: project, user: user, role: :member)
        sign_in user
      end

      it "returns 404 instead of proxying to a nil port" do
        session = create(:preview_session, :ready, :without_port, project: project,
          branch_name: "feature/transitional", token: "no-port-token")

        get "/previews/#{session.token}"

        expect(response).to have_http_status(:not_found)
      end
    end
  end

  describe "POST /projects/:project_id/preview_sessions/:id/stop" do
    let(:user) { create(:user, :admin, account: account) }

    before { sign_in user }

    it "marks the preview as stopped, tearing down its infrastructure, and redirects to the project" do
      reservation = PreviewTunnelPortReservation.create!(
        reservation_key: "preview_session:#{preview_session.id}",
        tunnel_port: preview_session.tunnel_port
      )
      container = instance_double(Docker::Container, info: { "State" => { "Running" => true } })
      backend = instance_double(Containers::Backends::Base)
      allow(backend).to receive(:get_container).and_return(container)
      allow(backend).to receive(:stop_container)
      allow(backend).to receive(:delete_container)
      allow(Containers).to receive(:backend).and_return(backend)

      post stop_project_preview_session_path(project, preview_session)

      expect(preview_session.reload.status).to eq("stopped")
      expect(response).to redirect_to(project_path(project))
      expect(PreviewTunnelPortReservation.exists?(reservation.id)).to be(false)
      expect(backend).to have_received(:delete_container).with(container, force: true, v: true)
    end

    it "does not allow a non-admin member to stop" do
      viewer = create(:user, :member, account: account)
      sign_out user
      sign_in viewer

      post stop_project_preview_session_path(project, preview_session)

      expect(preview_session.reload.status).to eq("ready")
    end
  end
end
