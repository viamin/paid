# frozen_string_literal: true

require "rails_helper"

RSpec.describe "CodexLoginSessions" do
  let(:account) { create(:account) }
  let(:owner_user) { create(:user, :owner, account: account) }

  describe "GET /codex_login_sessions/new" do
    before { sign_in owner_user }

    it "renders the form" do
      get new_codex_login_session_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Connect Codex")
    end

    it "drops unsafe return_to targets before rendering links" do
      get new_codex_login_session_path(return_to: "https://evil.example/phish")

      document = Nokogiri::HTML.parse(response.body)
      cancel_link = document.at_css("a[href^='/integration_credentials']")
      hidden_return_to = document.at_css("input[name='codex_login_session[metadata][return_to]']")

      expect(response).to have_http_status(:ok)
      expect(cancel_link["href"]).to eq(integration_credentials_path(category: "llm_provider", service_key: "openai"))
      expect(hidden_return_to["value"]).to be_nil
    end
  end

  describe "POST /codex_login_sessions" do
    before do
      sign_in owner_user
      allow(CodexLoginSessions::DeviceFlow).to receive(:call)
    end

    it "creates a session and starts the device flow" do
      expect {
        post codex_login_sessions_path, params: {
          codex_login_session: {
            credential_name: "Codex Connect Login"
          }
        }
      }.to change(CodexLoginSession, :count).by(1)

      session = CodexLoginSession.order(:id).last
      expect(CodexLoginSessions::DeviceFlow).to have_received(:call).with(session: session)
      expect(response).to redirect_to(codex_login_session_path(session.external_id))
    end

    it "sanitizes a tampered return_to before persisting metadata" do
      post codex_login_sessions_path, params: {
        codex_login_session: {
          credential_name: "Codex Connect Login",
          metadata: {
            return_to: "https://evil.example/phish"
          }
        }
      }

      expect(CodexLoginSession.order(:id).last.metadata["return_to"]).to be_nil
    end
  end

  describe "PATCH /codex_login_sessions/:id" do
    let!(:session_record) do
      create(
        :codex_login_session,
        :awaiting_authorization,
        account: account,
        created_by: owner_user
      )
    end

    before { sign_in owner_user }

    it "forwards the submitted session_token to the device flow" do
      flow = instance_double(CodexLoginSessions::DeviceFlow, poll!: { status: :pending, completed: false, error: nil })
      allow(CodexLoginSessions::DeviceFlow).to receive(:new).with(session: session_record).and_return(flow)

      patch codex_login_session_path(session_record.external_id), params: {
        session_token: session_record.session_token
      }

      expect(flow).to have_received(:poll!).with(session_token: session_record.session_token)
      expect(response).to redirect_to(codex_login_session_path(session_record.external_id))
    end

    it "still forwards a mismatched session_token so the flow can reject it" do
      flow = instance_double(CodexLoginSessions::DeviceFlow, poll!: { status: :failed, completed: false, error: "The Connect Codex login session token is invalid." })
      allow(CodexLoginSessions::DeviceFlow).to receive(:new).with(session: session_record).and_return(flow)

      patch codex_login_session_path(session_record.external_id), params: {
        session_token: "wrong-token"
      }

      expect(flow).to have_received(:poll!).with(session_token: "wrong-token")
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include("invalid")
    end

    it "forwards a nil session_token when the form omits it" do
      flow = instance_double(CodexLoginSessions::DeviceFlow, poll!: { status: :failed, completed: false, error: "The Connect Codex login session token is invalid." })
      allow(CodexLoginSessions::DeviceFlow).to receive(:new).with(session: session_record).and_return(flow)

      patch codex_login_session_path(session_record.external_id)

      expect(flow).to have_received(:poll!).with(session_token: nil)
      expect(response).to have_http_status(:unprocessable_content)
    end

    it "renders the failure alert when polling fails" do
      flow = instance_double(CodexLoginSessions::DeviceFlow, poll!: { status: :failed, completed: false, error: "This Connect Codex login session has expired." })
      allow(CodexLoginSessions::DeviceFlow).to receive(:new).with(session: session_record).and_return(flow)

      patch codex_login_session_path(session_record.external_id), params: {
        session_token: session_record.session_token
      }

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include("expired")
    end
  end

  describe "GET /codex_login_sessions/:id" do
    let!(:session_record) do
      create(
        :codex_login_session,
        :awaiting_authorization,
        account: account,
        created_by: owner_user,
        metadata: { "return_to" => "https://evil.example/phish" }
      )
    end

    before { sign_in owner_user }

    it "does not render an unsafe persisted return_to link" do
      get codex_login_session_path(session_record.external_id)

      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include("https://evil.example/phish")
      expect(response.body).not_to include("Return to Previous Page")
    end
  end
end
