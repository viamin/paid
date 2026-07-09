# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Admin::GithubApp::Setup" do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account, email: "operator@example.com") }

  before do
    ENV["PAID_OPERATOR_EMAILS"] = "operator@example.com"
    sign_in user
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
    let(:state) { SecureRandom.urlsafe_base64(32) }
    let(:code) { "abc123" }
    let(:pem) { OpenSSL::PKey::RSA.new(2048).to_pem }

    def with_setup_state(token: state)
      allow_any_instance_of(Admin::GithubApp::SetupController).to receive(:session)
        .and_return({ admin_github_app_setup_state: token })
    end

    it "exchanges the code, persists ENV, and audits the setup" do
      with_setup_state
      allow(Github::AppManifestExchanger).to receive(:call).with(code: code).and_return(
        Github::AppManifestExchanger::Result.new(
          app_id: 99,
          slug: "paid-agents-self-hosted",
          html_url: "https://github.com/apps/paid-agents-self-hosted",
          private_key: pem,
          webhook_secret: "shhh"
        )
      )

      get admin_github_app_setup_callback_path, params: { code: code, state: state }

      expect(response).to redirect_to(admin_github_app_setup_path)
      expect(flash[:notice]).to match(/paid-agents-self-hosted/)
      expect(ENV["PAID_AGENT_APP_ID"]).to eq("99")
      expect(ENV["PAID_AGENT_APP_SLUG"]).to eq("paid-agents-self-hosted")
      expect(ENV["PAID_AGENT_APP_PRIVATE_KEY"]).to eq(pem)
      expect(ENV["PAID_AGENT_APP_WEBHOOK_SECRET"]).to eq("shhh")
    end

    it "rejects mismatched state" do
      with_setup_state

      get admin_github_app_setup_callback_path, params: { code: code, state: "wrong" }

      expect(response).to redirect_to(admin_github_app_setup_path)
      expect(flash[:alert]).to match(/state did not match/i)
    end

    it "rejects missing code" do
      with_setup_state

      get admin_github_app_setup_callback_path, params: { state: state }

      expect(response).to redirect_to(admin_github_app_setup_path)
      expect(flash[:alert]).to match(/did not return a setup code/)
    end

    it "surfaces exchanger errors as a redirect alert" do
      with_setup_state
      allow(Github::AppManifestExchanger).to receive(:call).and_raise(
        Github::AppManifestExchanger::Error, "code expired"
      )

      get admin_github_app_setup_callback_path, params: { code: code, state: state }

      expect(response).to redirect_to(admin_github_app_setup_path)
      expect(flash[:alert]).to match(/code expired/)
    end
  end
end