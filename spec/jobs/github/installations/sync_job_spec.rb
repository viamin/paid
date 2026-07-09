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
end