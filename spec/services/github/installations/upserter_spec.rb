# frozen_string_literal: true

require "rails_helper"

RSpec.describe Github::Installations::Upserter do
  let(:account) { create(:account) }
  let(:github_installation_id) { 88_777_777 }

  def base_payload(action: "created", **overrides)
    {
      "action" => action,
      "installation" => {
        "id" => github_installation_id,
        "account" => { "login" => "acme-corp" },
        "target_type" => "Organization",
        "repository_selection" => "all",
        "repositories" => [
          { "id" => 101, "full_name" => "acme-corp/widgets", "name" => "widgets",
            "owner" => { "login" => "acme-corp" }, "default_branch" => "main",
            "private" => false }
        ]
      }
    }.deep_merge(overrides)
  end

  describe ".call" do
    it "creates a GithubInstallation from the payload" do
      expect {
        described_class.call(account: account, payload: base_payload)
      }.to change(GithubInstallation, :count).by(1)

      record = GithubInstallation.find_by(github_installation_id: github_installation_id)
      expect(record.account_id).to eq(account.id)
      expect(record.account_login).to eq("acme-corp")
      expect(record.target_type).to eq("Organization")
      expect(record.repository_selection).to eq("all")
      expect(record.accessible_repositories).to contain_exactly(
        hash_including("full_name" => "acme-corp/widgets")
      )
      expect(record.suspended_at).to be_nil
      expect(record.revoked_at).to be_nil
    end

    it "updates an existing record when one already exists" do
      existing = create(:github_installation, account: account,
                        github_installation_id: github_installation_id,
                        account_login: "old-login")

      expect {
        described_class.call(account: account, payload: base_payload)
      }.not_to change(GithubInstallation, :count)

      existing.reload
      expect(existing.account_login).to eq("acme-corp")
    end

    it "records repositories_synced_at when repositories are present" do
      record = described_class.call(account: account, payload: base_payload)
      expect(record.repositories_synced_at).to be_present
    end

    it "marks the installation suspended on installation.suspend" do
      record = described_class.call(account: account, payload: base_payload(action: "created"))
      described_class.call(account: account, payload: base_payload(action: "suspend"))

      expect(record.reload.suspended_at).to be_present
      expect(record.revoked_at).to be_nil
    end

    it "clears suspended_at on installation.unsuspend" do
      record = described_class.call(account: account, payload: base_payload(action: "suspend"))
      described_class.call(account: account, payload: base_payload(action: "unsuspend"))

      expect(record.reload.suspended_at).to be_nil
    end

    it "marks revoked_at on installation.deleted without clearing suspended_at unless needed" do
      record = described_class.call(account: account, payload: base_payload(action: "suspend"))
      described_class.call(account: account, payload: base_payload(action: "deleted"))

      record.reload
      expect(record.revoked_at).to be_present
      expect(record.suspended_at).to be_nil
    end

    it "does not move an installation between accounts on update" do
      other_account = create(:account)
      create(:github_installation, account: other_account,
             github_installation_id: github_installation_id)

      described_class.call(account: account, payload: base_payload)

      expect(GithubInstallation.find_by(github_installation_id: github_installation_id).account_id)
        .to eq(other_account.id)
    end

    it "raises when the payload is missing installation.id" do
      payload = base_payload
      payload["installation"].delete("id")

      expect {
        described_class.call(account: account, payload: payload)
      }.to raise_error(Github::Installations::Upserter::Error, /missing installation.id/)
    end

    it "scopes find-or-initialize to the same installation globally" do
      other = create(:account)
      create(:github_installation, account: other, github_installation_id: github_installation_id)

      expect {
        described_class.call(account: account, payload: base_payload)
      }.not_to change(GithubInstallation, :count)
    end
  end
end
