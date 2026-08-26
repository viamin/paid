# frozen_string_literal: true

require "rails_helper"

# @spec GITHUB-SYNC-004
RSpec.describe "GithubApp::Installations lifecycle" do
  include Warden::Test::Helpers

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

    it "escapes the GitHub App slug before redirecting" do
      allow(Github::AppRegistry).to receive(:slug).and_return("paid-agents/../../evil")
      allow(Github::AppRegistry).to receive(:install_url).and_call_original

      get github_app_install_path

      expect(response.location).to start_with("https://github.com/apps/paid-agents%2F..%2F..%2Fevil/installations/new?state=")
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
    let(:installation_id) { 88_777_777 }

    # Drives the controller through a real `install` request so the resulting
    # session state is set by the controller itself. The returned token is
    # what the callback must echo to be accepted.
    def prime_session
      get github_app_install_path
      stored = request.session[:github_app_install_state]
      stored[:token] || stored["token"]
    end

    it "creates a PendingInstallClaim, enqueues a SyncJob, and redirects to integrations on a valid state" do
      token = prime_session

      expect {
        get github_app_callback_path, params: {
          installation_id: installation_id, setup_action: "install", state: token
        }
      }.to have_enqueued_job(Github::Installations::SyncJob).with(
        installation_id: installation_id,
        account_id: account.id,
        setup_action: "install"
      )

      expect(response).to redirect_to(integrations_path)
      expect(flash[:notice]).to match(/installation received/i)

      claim = TenantContext.with_system_access do
        PendingInstallClaim.find_by(github_installation_id: installation_id)
      end
      expect(claim).to be_present
      expect(claim.account_id).to eq(account.id)
      expect(claim.source).to eq("callback_with_state")
      expect(claim.state_token).to eq(token)
    end

    it "prefers the session-stored account_id over the current_account fallback" do
      other_account = create(:account)
      controller = GithubApp::InstallationsController.new
      allow(controller).to receive_messages(
        session: {
          GithubApp::InstallationsController::INSTALL_STATE_SESSION_KEY => { account_id: other_account.id }
        },
        current_account: account
      )

      resolved_account_id = controller.send(:session_account_id) || controller.current_account&.id

      expect(resolved_account_id).to eq(other_account.id)
    end

    it "rejects mismatched state" do
      prime_session

      get github_app_callback_path, params: {
        installation_id: installation_id, setup_action: "install", state: "wrong-token"
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
        installation_id: installation_id, setup_action: "install", state: token
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

    # A non-operator hitting the callback with no session state has no signal
    # we can trust: the state CSRF was not verified (none was minted), and
    # the user is not an operator, so no PendingInstallClaim is created.
    # The SyncJob will then refuse to bind (no claim, no row, no project
    # match) and the install is effectively dropped — the security property
    # the reviewer flagged.
    it "does not create a PendingInstallClaim when a non-operator arrives without session state" do
      get github_app_callback_path, params: {
        installation_id: installation_id, setup_action: "install"
      }

      expect(response).to redirect_to(integrations_path)

      claim = TenantContext.with_system_access do
        PendingInstallClaim.find_by(github_installation_id: installation_id)
      end
      expect(claim).to be_nil
    end

    it "still enqueues a SyncJob on a GitHub-initiated redirect so the secondary-signal check runs" do
      expect {
        get github_app_callback_path, params: {
          installation_id: installation_id, setup_action: "install"
        }
      }.to have_enqueued_job(Github::Installations::SyncJob).with(
        installation_id: installation_id,
        account_id: account.id,
        setup_action: "install"
      )
    end

    context "when the current user is an operator on a freshly-configured self-hosted App" do
      let(:operator) { create(:user, account: account) }

      around do |example|
        original = ENV["PAID_OPERATOR_EMAILS"]
        ENV["PAID_OPERATOR_EMAILS"] = operator.email
        example.run
      ensure
        ENV["PAID_OPERATOR_EMAILS"] = original
      end

      before do
        sign_out user
        sign_in operator
      end

      it "creates an operator_setup claim so the webhook can finalize the binding" do
        get github_app_callback_path, params: {
          installation_id: installation_id, setup_action: "install"
        }

        expect(response).to redirect_to(integrations_path)

        claim = TenantContext.with_system_access do
          PendingInstallClaim.find_by(github_installation_id: installation_id)
        end
        expect(claim).to be_present
        expect(claim.account_id).to eq(account.id)
        expect(claim.source).to eq("operator_setup")
      end
    end
  end
end
