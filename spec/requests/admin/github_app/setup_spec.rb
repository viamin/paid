# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Admin::GithubApp::Setup" do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account, email: "operator@example.com") }
  let(:pem) { OpenSSL::PKey::RSA.new(2048).to_pem }
  let(:exchanger_result) do
    Github::AppManifestExchanger::Result.new(
      app_id: 99,
      slug: "paid-agents-self-hosted",
      html_url: "https://github.com/apps/paid-agents-self-hosted",
      private_key: pem,
      webhook_secret: "shhh"
    )
  end

  before do
    ENV["PAID_OPERATOR_EMAILS"] = "operator@example.com"
    sign_in user
    allow(Github::AppManifestExchanger).to receive(:call).and_return(exchanger_result)
  end

  after do
    ENV.delete("PAID_OPERATOR_EMAILS")
    ENV.delete("PAID_AGENT_APP_ID")
    ENV.delete("PAID_AGENT_APP_SLUG")
    ENV.delete("PAID_AGENT_APP_PRIVATE_KEY")
    ENV.delete("PAID_AGENT_APP_WEBHOOK_SECRET")
  end

  describe "GET /admin/github_app/setup" do
    it "renders the setup page for operators" do
      get admin_github_app_setup_path

      expect(response).to have_http_status(:ok)
    end

    it "redirects non-operators" do
      member = create(:user, account: account, email: "member@example.com")
      sign_out user
      sign_in member

      get admin_github_app_setup_path

      expect(response).to redirect_to(root_path)
      expect(flash[:alert]).to match(/not authorized/i)
    end

    it "reports webhook secret configured from ENV or credentials" do
      allow(Github::AppRegistry).to receive(:webhook_secret).and_return(nil)
      get admin_github_app_setup_path
      expect(response.body).to include("Missing")

      allow(Github::AppRegistry).to receive(:webhook_secret).and_return("shhh")
      get admin_github_app_setup_path
      expect(response.body).to include("Configured")
    end
  end

  describe "POST /admin/github_app/setup" do
    it "redirects to GitHub with a base64-encoded manifest" do
      post admin_github_app_setup_path

      expect(response).to have_http_status(:found)
      expect(response.location).to start_with("https://github.com/settings/apps/new?manifest=")

      decoded = Base64.urlsafe_decode64(
        CGI.unescape(response.location.split("manifest=").last)
      )
      manifest = JSON.parse(decoded)
      expect(manifest["name"]).to be_present
      expect(manifest["public"]).to be(false)
      expect(manifest["default_permissions"]).to include(
        "contents" => "write",
        "pull_requests" => "write",
        "issues" => "write"
      )
    end

    it "stores a one-shot state in the session" do
      post admin_github_app_setup_path

      state = request.session[:admin_github_app_setup_state]
      expect(state).to be_present
    end
  end

  describe "GET /admin/github_app/setup/callback" do
    let(:code) { "abc123" }

    # Drives the controller through a real `POST /admin/github_app/setup`
    # request so the resulting session state is set by the controller itself.
    # Returns the state token echoed back by GitHub in the callback.
    def primed_state
      post admin_github_app_setup_path
      request.session[:admin_github_app_setup_state]
    end

    it "exchanges the code, hands the result to the persister, and audits the setup" do
      state = primed_state
      original_app_id = ENV["PAID_AGENT_APP_ID"]
      original_webhook_secret = ENV["PAID_AGENT_APP_WEBHOOK_SECRET"]
      allow(Github::AppCredentialsPersister).to receive(:call)
        .with(result: exchanger_result)
        .and_return(
          Github::AppCredentialsPersister::Result.new(
            status: :persisted,
            credentials_path: "/workspace/config/credentials/production.yml.enc",
            written_keys: %w[paid_agent_app_id paid_agent_app_private_key paid_agent_app_slug paid_agent_app_webhook_secret]
          )
        )

      get admin_github_app_setup_callback_path, params: { code: code, state: state }

      expect(response).to redirect_to(admin_github_app_setup_path)
      expect(flash[:notice]).to include("paid-agents-self-hosted")
      expect(flash[:notice]).to match(/written to/i)
      expect(Github::AppCredentialsPersister).to have_received(:call).with(result: exchanger_result)
      expect(ENV["PAID_AGENT_APP_ID"]).to eq(original_app_id)
      expect(ENV["PAID_AGENT_APP_WEBHOOK_SECRET"]).to eq(original_webhook_secret)
    end

    it "surfaces manual instructions when the persister cannot write credentials" do
      state = primed_state
      allow(Github::AppCredentialsPersister).to receive(:call)
        .with(result: exchanger_result)
        .and_return(
          Github::AppCredentialsPersister::Result.new(
            status: :manual,
            credentials_path: "/workspace/config/credentials/production.yml.enc",
            written_keys: [],
            manual_instructions: "Add PAID_AGENT_APP_ID, PAID_AGENT_APP_SLUG, ..."
          )
        )

      get admin_github_app_setup_callback_path, params: { code: code, state: state }

      expect(response).to redirect_to(admin_github_app_setup_path)
      expect(flash[:notice]).to include("NOT persisted automatically")
    end

    it "rejects mismatched state" do
      primed_state

      get admin_github_app_setup_callback_path, params: { code: code, state: "wrong" }

      expect(response).to redirect_to(admin_github_app_setup_path)
      expect(flash[:alert]).to match(/state did not match/i)
    end

    it "rejects missing code" do
      state = primed_state

      get admin_github_app_setup_callback_path, params: { state: state }

      expect(response).to redirect_to(admin_github_app_setup_path)
      expect(flash[:alert]).to include("did not return a setup code")
    end

    it "surfaces exchanger errors as a redirect alert" do
      state = primed_state
      allow(Github::AppManifestExchanger).to receive(:call).and_raise(
        Github::AppManifestExchanger::Error, "code expired"
      )

      get admin_github_app_setup_callback_path, params: { code: code, state: state }

      expect(response).to redirect_to(admin_github_app_setup_path)
      expect(flash[:alert]).to include("code expired")
    end
  end
end
