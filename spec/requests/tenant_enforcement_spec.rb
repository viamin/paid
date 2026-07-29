# frozen_string_literal: true

require "rails_helper"

RSpec.describe "TenantEnforcement" do
  describe "active account" do
    let(:account) { create(:account, status: :active) }
    let(:user) { create(:user, account: account) }

    before { sign_in user }

    it "allows GET requests" do
      get root_path
      expect(response).to have_http_status(:ok)
    end
  end

  describe "suspended account" do
    let(:account) { create(:account, status: :suspended, suspended_at: Time.current) }
    let(:user) { create(:user, :owner, account: account) }

    before { sign_in user }

    it "allows GET requests" do
      get root_path
      expect(response).to have_http_status(:ok)
    end

    it "blocks POST requests with a redirect" do
      post projects_path, params: { project: { name: "test" } }
      expect(response).to redirect_to(root_path)
    end

    it "sets a flash alert for blocked mutations" do
      post projects_path, params: { project: { name: "test" } }
      expect(flash[:alert]).to match(/suspended/i)
    end

    it "returns forbidden json for JSON mutations" do
      post chat_sessions_path(format: :json), params: { container_capability: "none", title: "Blocked chat" }

      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body).to eq("error" => "This account is suspended. Write operations are disabled.")
    end

    it "returns forbidden SSE for streaming mutations" do
      chat_session = create(:chat_session, account: account, created_by: user)

      post chat_session_chat_messages_path(chat_session),
        params: { content: "Hello" },
        headers: { "Accept" => "text/event-stream" }

      expect(response).to have_http_status(:forbidden)
      expect(response.media_type).to eq("text/event-stream")
      expect(response.body).to include("event: error")
      expect(response.body).to include("suspended")
    end
  end

  describe "deactivated account" do
    let(:account) { create(:account, status: :deactivated, deactivated_at: Time.current) }
    let(:user) { create(:user, account: account) }

    before { sign_in user }

    it "redirects to sign in on GET" do
      get root_path
      expect(response).to redirect_to(new_user_session_path)
    end

    it "redirects to sign in on POST" do
      post projects_path, params: { project: { name: "test" } }
      expect(response).to redirect_to(new_user_session_path)
    end

    it "sets a deactivation alert" do
      get root_path
      expect(flash[:alert]).to match(/deactivated/i)
    end

    it "returns a deactivation error for JSON requests" do
      get chat_sessions_path(format: :json), headers: { "Accept" => "application/json" }

      expect(response).to have_http_status(:unauthorized)
      expect(response.parsed_body).to eq("error" => "This account has been deactivated. Please contact support.")
    end
  end
end
