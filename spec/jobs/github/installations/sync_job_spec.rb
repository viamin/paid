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

  it "fetches the installation and upserts the record" do
    # Brand-new install into a fresh org has no project to verify against —
    # create a project owner first so the binding check passes.
    create(:project, account: account, owner: "acme-corp", repo: "widgets")

    stub_request(:get, %r{/app/installations/#{installation_id}\z})
      .to_return(status: 200, body: installation_payload.to_json,
                 headers: { "Content-Type" => "application/json" })
    allow(Github::Installations::Upserter).to receive(:call).and_call_original

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

  # GitHub's setup URL `installation_id` is spoofable; CSRF state only proves
  # the user clicked Paid's install button, not that they completed the
  # GitHub-side install. We refuse to bind a callback-driven sync unless the
  # JWT-fetched installation matches a signal we already trust.
  describe "callback binding verification" do
    let(:installation_url) { %r{/app/installations/#{installation_id}\z} }

    before do
      stub_request(:get, installation_url)
        .to_return(status: 200, body: installation_payload.to_json,
                   headers: { "Content-Type" => "application/json" })
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

    it "refuses to bind a brand-new installation into an org with no projects (defer to webhook)" do
      expect {
        described_class.perform_now(
          installation_id: installation_id,
          account_id: account.id,
          setup_action: "install"
        )
      }.not_to change(GithubInstallation, :count)
    end

    it "refuses to bind an installation whose account_login does not match any project owner in the account" do
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
