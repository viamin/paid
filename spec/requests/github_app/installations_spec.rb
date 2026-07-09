# frozen_string_literal: true

require "rails_helper"

RSpec.describe "GithubApp::Installations lifecycle" do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:app_id) { "123456" }
  let(:private_key) { OpenSSL::PKey::RSA.new(2048).to_pem }

  before do
    sign_in user
    allow(Github::AppRegistry).to receive_messages(configured?: true, app_id: app_id, private_key: private_key, slug: "paid-agents")
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

    # Drives the controller through a real `install` request so the resulting
    # session state is set by the controller itself. The returned token is
    # what the callback must echo to be accepted.
    def prime_session
      get github_app_install_path
      stored = request.session[:github_app_install_state]
      stored[:token] || stored["token"]
    end

    it "enqueues a SyncJob and redirects to integrations on a valid state" do
      token = prime_session

      expect {
        get github_app_callback_path, params: {
          installation_id: 88_777_777, setup_action: "install", state: token
        }
      }.to have_enqueued_job(Github::Installations::SyncJob).with(
        installation_id: 88_777_777,
        account_id: account.id,
        setup_action: "install"
      )

      expect(response).to redirect_to(integrations_path)
      expect(flash[:notice]).to match(/installation received/i)
    end

    it "captures the session-stored account_id before clearing state" do
      # Switch to a different account before priming the session so the
      # stored account_id differs from the one the controller would otherwise
      # fall back to (current_account.id at callback time).
      other_account = create(:account)
      other_user = create(:user, account: other_account)
      sign_out user
      sign_in other_user

      get github_app_install_path
      stored = request.session[:github_app_install_state]
      token = stored[:token] || stored["token"]

      # After sign_in the install request wrote other_account.id; now sign
      # back in as the original user so the controller's fallback path would
      # pick account.id if it ever ignored the session-stored value.
      sign_out other_user
      sign_in user

      expect {
        get github_app_callback_path, params: {
          installation_id: 88_777_777, setup_action: "install", state: token
        }
      }.to have_enqueued_job(Github::Installations::SyncJob).with(
        installation_id: 88_777_777,
        account_id: other_account.id,
        setup_action: "install"
      )
    end

    it "rejects mismatched state" do
      prime_session

      get github_app_callback_path, params: {
        installation_id: 88_777_777, setup_action: "install", state: "wrong-token"
      }

      expect(response).to redirect_to(integrations_path)
      expect(flash[:alert]).to match(/state did not match/i)
    end

    it "rejects expired state" do
      # Back-date the install so the issued_at timestamp is older than the
      # 15-minute TTL before the controller ever sees it.
      travel_to(1.hour.ago) do
        get github_app_install_path
      end
      token = request.session[:github_app_install_state][:token] || request.session[:github_app_install_state]["token"]

      get github_app_callback_path, params: {
        installation_id: 88_777_777, setup_action: "install", state: token
      }

      expect(response).to redirect_to(integrations_path)
      expect(flash[:alert]).to match(/expired/i)
    end

    it "redirects when installation_id is missing" do
      token = prime_session

      get github_app_callback_path, params: {
        setup_action: "install", state: token
      }

      expect(response).to redirect_to(integrations_path)
      expect(flash[:alert]).to match(/Missing installation_id/i)
    end
  end
end