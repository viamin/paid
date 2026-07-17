# frozen_string_literal: true

require "rails_helper"

RSpec.describe Github::Installations::SyncJob do
  let(:account) { create(:account) }
  let(:installation_id) { 12_345 }
  let(:private_key) { OpenSSL::PKey::RSA.new(2048).to_pem }
  let(:installation_payload) do
    {
      "id" => installation_id,
      "account" => { "login" => "acme-corp" },
      "target_type" => "Organization",
      "repository_selection" => "all"
    }
  end

  around do |example|
    original_id = ENV["PAID_AGENT_APP_ID"]
    original_key = ENV["PAID_AGENT_APP_PRIVATE_KEY"]
    ENV["PAID_AGENT_APP_ID"] = "123456"
    ENV["PAID_AGENT_APP_PRIVATE_KEY"] = private_key
    example.run
  ensure
    ENV["PAID_AGENT_APP_ID"] = original_id
    ENV["PAID_AGENT_APP_PRIVATE_KEY"] = original_key
  end

  it "fetches the installation and upserts the record when an existing row maps this installation" do
    stub_request(:get, %r{/app/installations/#{installation_id}\z})
      .to_return(status: 200, body: installation_payload.to_json,
                 headers: { "Content-Type" => "application/json" })
    allow(Github::Installations::Upserter).to receive(:call).and_call_original
    create(:github_installation, account: account, github_installation_id: installation_id)

    described_class.perform_now(
      installation_id: installation_id,
      account_id: account.id,
      setup_action: "install"
    )

    record = TenantContext.with_system_access do
      GithubInstallation.find_by(github_installation_id: installation_id)
    end
    expect(record).to be_present
    expect(record.account_id).to eq(account.id)
    expect(Github::Installations::Upserter).to have_received(:call)
      .with(hash_including(account: account,
        payload: hash_including("action" => "created",
                                "installation" => hash_including("id" => installation_id))))
  end

  it "ignores missing accounts" do
    expect {
      described_class.perform_now(
        installation_id: installation_id,
        account_id: -1,
        setup_action: "install"
      )
    }.not_to change(GithubInstallation, :count)
  end

  it "logs and ignores transport errors" do
    stub_request(:get, %r{/app/installations/#{installation_id}\z})
      .to_return(status: 500, body: { message: "boom" }.to_json)

    expect {
      described_class.perform_now(
        installation_id: installation_id,
        account_id: account.id,
        setup_action: "install"
      )
    }.not_to change(GithubInstallation, :count)
  end

  describe "callback binding verification" do
    let(:installation_url) { %r{/app/installations/#{installation_id}\z} }

    before do
      stub_request(:get, installation_url)
        .to_return(status: 200, body: installation_payload.to_json,
                   headers: { "Content-Type" => "application/json" })
    end

    it "binds when an active PendingInstallClaim exists for the (installation_id, account_id) pair" do
      PendingInstallClaim.upsert_for_callback!(
        account: account,
        installation_id: installation_id,
        source: "callback_with_state",
        state_token: "claimed-token"
      )

      expect {
        described_class.perform_now(
          installation_id: installation_id,
          account_id: account.id,
          setup_action: "install"
        )
      }.to change(GithubInstallation, :count).by(1)
    end

    it "ignores expired claims (defers binding to the webhook or operator recovery)" do
      PendingInstallClaim.upsert_for_callback!(
        account: account,
        installation_id: installation_id,
        source: "callback_with_state"
      )
      TenantContext.with_system_access do
        PendingInstallClaim.where(github_installation_id: installation_id)
          .update_all(expires_at: 1.hour.ago)
      end

      expect {
        described_class.perform_now(
          installation_id: installation_id,
          account_id: account.id,
          setup_action: "install"
        )
      }.not_to change(GithubInstallation, :count)
    end

    it "binds when the installation's account.login matches a project owner in the account" do
      create(:project, account: account, owner: "acme-corp", repo: "widgets")

      expect {
        described_class.perform_now(
          installation_id: installation_id,
          account_id: account.id,
          setup_action: "install"
        )
      }.to change(GithubInstallation, :count).by(1)
    end

    it "binds when an existing GithubInstallation row already maps this installation to the account" do
      existing = create(:github_installation, account: account,
                        github_installation_id: installation_id,
                        account_login: "old-login")

      described_class.perform_now(
        installation_id: installation_id,
        account_id: account.id,
        setup_action: "install"
      )

      expect(existing.reload.account_login).to eq("acme-corp")
    end

    it "refuses to bind a callback that has no claim, no row, and no project match (defer to webhook)" do
      expect {
        described_class.perform_now(
          installation_id: installation_id,
          account_id: account.id,
          setup_action: "install"
        )
      }.not_to change(GithubInstallation, :count)
    end

    it "refuses to bind a callback whose account_login does not match any project owner" do
      create(:project, account: account, owner: "different-org", repo: "widgets")

      expect {
        described_class.perform_now(
          installation_id: installation_id,
          account_id: account.id,
          setup_action: "install"
        )
      }.not_to change(GithubInstallation, :count)
    end
  end
end
