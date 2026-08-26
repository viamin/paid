# frozen_string_literal: true

require "rails_helper"

RSpec.describe "ClaudeLoginSessions" do
  let(:account) { create(:account) }
  let(:owner_user) { create(:user, :owner, account: account) }
  let(:admin_user) { create(:user, :admin, account: account) }
  let(:member_user) { create(:user, :member, account: account) }

  describe "GET /claude_login_sessions/new" do
    before { sign_in owner_user }

    it "renders the form" do
      get new_claude_login_session_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Claude Browser Login")
    end

    # @spec SUBSCRIPTION-RUNNER-AUTH-004
    context "with an active claude runner credential" do
      let!(:runner) { owner_user.runners.find_or_create_by!(runner_key: "claude") }
      let!(:credential) do
        create(
          :runner_credential,
          account: account,
          runner_key: "claude",
          name: "Existing Claude Credential",
          created_by: owner_user,
          expires_at: 1.week.from_now
        )
      end

      it "shows the active credential status with a link to it" do
        get new_claude_login_session_path

        expect(response).to have_http_status(:ok)
        expect(response.body).to include("Active Claude credential")
        expect(response.body).to include("Existing Claude Credential")
        expect(response.body).to include("second concurrent active credential")

        hrefs = Nokogiri::HTML.parse(response.body).css("a").map { |link| link["href"] }
        expect(hrefs).to include(runner_runner_credential_path(runner, credential))
        expect(hrefs).to include(integration_credentials_path(category: "llm_provider", service_key: "claude"))
      end

      it "never renders token material" do
        get new_claude_login_session_path

        expect(response.body).not_to include(credential.token)
      end
    end

    # @spec SUBSCRIPTION-RUNNER-AUTH-004
    context "with only an inactive claude runner credential" do
      it "renders the fresh login form without a status banner" do
        create(
          :runner_credential,
          account: account,
          runner_key: "claude",
          name: "Expired Claude Credential",
          created_by: owner_user,
          expires_at: 1.hour.ago
        )

        get new_claude_login_session_path

        expect(response).to have_http_status(:ok)
        expect(response.body).not_to include("Active Claude credential")
      end
    end

    it "denies account members without admin privileges" do
      sign_out owner_user
      sign_in member_user

      get new_claude_login_session_path

      expect(response).to redirect_to(root_path)
      expect(flash[:alert]).to include("not authorized")
    end

    it "drops unsafe return_to targets before rendering links" do
      get new_claude_login_session_path(return_to: "https://evil.example/phish")

      document = Nokogiri::HTML.parse(response.body)
      cancel_link = document.at_css("a[href^='/integration_credentials']")
      hidden_return_to = document.at_css("input[name='claude_login_session[metadata][return_to]']")

      expect(response).to have_http_status(:ok)
      expect(cancel_link["href"]).to eq(integration_credentials_path(category: "llm_provider", service_key: "claude"))
      expect(hidden_return_to["value"]).to be_nil
    end

    it "drops protocol-relative return_to targets before rendering links" do
      get new_claude_login_session_path(return_to: "//evil.example/phish")

      document = Nokogiri::HTML.parse(response.body)
      cancel_link = document.at_css("a[href^='/integration_credentials']")
      hidden_return_to = document.at_css("input[name='claude_login_session[metadata][return_to]']")

      expect(response).to have_http_status(:ok)
      expect(cancel_link["href"]).to eq(integration_credentials_path(category: "llm_provider", service_key: "claude"))
      expect(hidden_return_to["value"]).to be_nil
    end
  end

  describe "POST /claude_login_sessions" do
    before do
      sign_in owner_user
      allow(ClaudeLoginSessions::Start).to receive(:call)
    end

    it "creates a session and starts the login flow" do
      expect {
        post claude_login_sessions_path, params: {
          claude_login_session: {
            credential_name: "Claude Browser Login"
          }
        }
      }.to change(ClaudeLoginSession, :count).by(1)

      session = ClaudeLoginSession.order(:id).last
      expect(ClaudeLoginSessions::Start).to have_received(:call).with(session: session)
      expect(response).to redirect_to(claude_login_session_path(session.external_id))
    end

    it "allows admins" do
      sign_out owner_user
      sign_in admin_user

      post claude_login_sessions_path, params: {
        claude_login_session: {
          credential_name: "Admin Claude Login"
        }
      }

      expect(response).to redirect_to(claude_login_session_path(ClaudeLoginSession.order(:id).last.external_id))
    end

    it "sanitizes a tampered return_to before persisting metadata" do
      post claude_login_sessions_path, params: {
        claude_login_session: {
          credential_name: "Claude Browser Login",
          metadata: {
            return_to: "https://evil.example/phish"
          }
        }
      }

      expect(ClaudeLoginSession.order(:id).last.metadata["return_to"]).to be_nil
    end

    it "drops a protocol-relative return_to before persisting metadata" do
      post claude_login_sessions_path, params: {
        claude_login_session: {
          credential_name: "Claude Browser Login",
          metadata: {
            return_to: "//evil.example/phish"
          }
        }
      }

      expect(ClaudeLoginSession.order(:id).last.metadata["return_to"]).to be_nil
    end
  end

  describe "PATCH /claude_login_sessions/:id" do
    let!(:session_record) do
      create(
        :claude_login_session,
        account: account,
        created_by: owner_user,
        status: "awaiting_code"
      )
    end

    before do
      sign_in owner_user
      allow(ClaudeLoginSessions::SubmitCode).to receive(:call)
        .and_return(ClaudeLoginSessions::SubmitCode::Result.new(success?: true, error_message: nil))
    end

    it "submits the browser code to the live session" do
      patch claude_login_session_path(session_record.external_id), params: {
        authorization_code: "code-123",
        session_token: session_record.session_token
      }

      expect(ClaudeLoginSessions::SubmitCode).to have_received(:call).with(
        session: session_record,
        session_token: session_record.session_token,
        code: "code-123"
      )
      expect(response).to redirect_to(claude_login_session_path(session_record.external_id))
    end
  end

  describe "GET /claude_login_sessions/:id" do
    let!(:session_record) do
      create(
        :claude_login_session,
        account: account,
        created_by: owner_user,
        status: "failed",
        metadata: { "return_to" => "https://evil.example/phish" }
      )
    end

    before { sign_in owner_user }

    it "does not render an unsafe persisted return_to link" do
      get claude_login_session_path(session_record.external_id)

      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include("https://evil.example/phish")
      expect(response.body).not_to include("Return to Previous Page")
    end
  end
end
