# frozen_string_literal: true

require "rails_helper"

RSpec.describe "GithubApp::Installations lifecycle" do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:app_id) { "123456" }
  let(:private_key) { OpenSSL::PKey::RSA.new(2048).to_pem }

  before do
    sign_in user
    allow(Github::AppRegistry).to receive(:configured?).and_return(true)
    allow(Github::AppRegistry).to receive(:app_id).and_return(app_id)
    allow(Github::AppRegistry).to receive(:private_key).and_return(private_key)
    allow(Github::AppRegistry).to receive(:slug).and_return("paid-agents")
    allow(Github::AppRegistry).to receive(:install_url) do |state:|
      "https://github.com/apps/paid-agents/installations/new?state=#{state}"
    end
  end

  describe "GET /github_app/install" do
    it "stores a CSRF state in the session and redirects to GitHub" do
      get github_app_install_path

      expect(response).to redirect_to(/\Ahttps:\/\/github\.com\/apps\/paid-agents\/installations\/new\?state=/)
      expect(response).to have_http_status(:found)
      expect(request.session[:github_app_install_state]).to be_present
    end

    it "persists the current account in the install state" do
      get github_app_install_path
      state = request.session[:github_app_install_state]
      expect(state[:account_id]).to eq(account.id)
    end

    it "redirects to integrations when the App is not configured" do
      allow(Github::AppRegistry).to receive(:configured?).and_return(false)

      get github_app_install_path

      expect(response).to redirect_to(integrations_path)
      expect(flash[:alert]).to match(/not configured/i)
    end
  end

  describe "GET /github_app/callback" do
    let(:state_token) { SecureRandom.urlsafe_base64(32) }

    def with_install_state(issued_at: Time.current.to_i, token: state_token)
      payload = {
        token: token,
        account_id: account.id,
        issued_at: issued_at
      }
      allow_any_instance_of(GithubApp::InstallationsController).to receive(:session)
        .and_return({ github_app_install_state: payload })
    end

    it "enqueues a SyncJob and redirects to integrations on a valid state" do
      with_install_state

      expect {
        get github_app_callback_path, params: {
          installation_id: 88_777_777, setup_action: "install", state: state_token
        }
      }.to have_enqueued_job(Github::Installations::SyncJob).with(
        installation_id: 88_777_777,
        account_id: account.id,
        setup_action: "install"
      )

      expect(response).to redirect_to(integrations_path)
      expect(flash[:notice]).to match(/installation received/i)
    end

    it "rejects mismatched state" do
      with_install_state

      get github_app_callback_path, params: {
        installation_id: 88_777_777, setup_action: "install", state: "wrong-token"
      }

      expect(response).to redirect_to(integrations_path)
      expect(flash[:alert]).to match(/state did not match/i)
    end

    it "rejects expired state" do
      with_install_state(issued_at: 1.hour.ago.to_i)

      get github_app_callback_path, params: {
        installation_id: 88_777_777, setup_action: "install", state: state_token
      }

      expect(response).to redirect_to(integrations_path)
      expect(flash[:alert]).to match(/expired/i)
    end

    it "redirects when installation_id is missing" do
      with_install_state

      get github_app_callback_path, params: {
        setup_action: "install", state: state_token
      }

      expect(response).to redirect_to(integrations_path)
      expect(flash[:alert]).to match(/Missing installation_id/i)
    end
  end
end