# frozen_string_literal: true

require "rails_helper"

RSpec.describe Github::Installations::AccountResolver do
  let(:account) { create(:account) }

  def installation_payload(installation_id:, login: "acme-corp",
                          installation_repositories: nil, payload_repositories: nil)
    {
      "action" => "created",
      "installation" => {
        "id" => installation_id,
        "account" => { "login" => login },
        "repository_selection" => "selected"
      }.merge(installation_repositories ? { "repositories" => installation_repositories } : {}),
      "repositories" => payload_repositories
    }.compact
  end

  describe ".call" do
    it "returns nil for an empty payload" do
      expect(described_class.call(payload: {})).to be_nil
    end

    it "returns the account bound to an existing installation row" do
      installation = create(:github_installation, account: account,
                            github_installation_id: 88_777_777,
                            account_login: "acme-corp")

      resolved = described_class.call(
        payload: installation_payload(installation_id: installation.github_installation_id)
      )

      expect(resolved).to eq(account)
    end

    # GitHub's installation webhooks put `repositories` at the top level of
    # the payload (alongside `installation`), not under `installation`. The
    # resolver must consult the top-level field so it can recover a deleted
    # row for an org that already has Projects.
    it "matches projects using top-level repositories from webhook payloads" do
      create(:project, account: account, owner: "acme-corp", repo: "widgets")
      create(:project, account: account, owner: "acme-corp", repo: "gadgets")

      resolved = described_class.call(
        payload: installation_payload(
          installation_id: 88_777_777,
          payload_repositories: [
            { "id" => 1, "full_name" => "acme-corp/widgets" },
            { "id" => 2, "full_name" => "acme-corp/gadgets" }
          ]
        )
      )

      expect(resolved).to eq(account)
    end

    it "still matches projects when repositories are nested under installation" do
      create(:project, account: account, owner: "acme-corp", repo: "widgets")

      resolved = described_class.call(
        payload: installation_payload(
          installation_id: 88_777_777,
          installation_repositories: [
            { "id" => 1, "full_name" => "acme-corp/widgets" }
          ]
        )
      )

      expect(resolved).to eq(account)
    end

    it "matches projects via the installation's account.login when no repositories are present" do
      create(:github_installation, account: account,
             github_installation_id: 88_777_777,
             account_login: "acme-corp")

      resolved = described_class.call(
        payload: installation_payload(installation_id: 88_777_777)
      )

      expect(resolved).to eq(account)
    end

    it "returns nil when no heuristic produces a unique match" do
      other_account = create(:account)
      create(:project, account: account, owner: "acme-corp", repo: "widgets")
      create(:project, account: other_account, owner: "acme-corp", repo: "gadgets")

      resolved = described_class.call(
        payload: installation_payload(
          installation_id: 88_777_777,
          payload_repositories: [
            { "id" => 1, "full_name" => "acme-corp/widgets" },
            { "id" => 2, "full_name" => "acme-corp/gadgets" }
          ]
        )
      )

      expect(resolved).to be_nil
    end

    it "batches the project lookup into a single query regardless of repository count" do
      create(:project, account: account, owner: "acme-corp", repo: "widgets")
      create(:project, account: account, owner: "acme-corp", repo: "gadgets")
      create(:project, account: account, owner: "acme-corp", repo: "sprockets")

      query_count = 0
      counter = ->(_name, _start, _finish, _id, payload) {
        query_count += 1 if payload[:sql] =~ /projects/i && payload[:sql] !~ /SCHEMA|TRANSACTION/i
      }
      ActiveSupport::Notifications.subscribed(counter, "sql.active_record") do
        described_class.call(
          payload: installation_payload(
            installation_id: 88_777_777,
            payload_repositories: [
              { "id" => 1, "full_name" => "acme-corp/widgets" },
              { "id" => 2, "full_name" => "acme-corp/gadgets" },
              { "id" => 3, "full_name" => "acme-corp/sprockets" }
            ]
          )
        )
      end

      expect(query_count).to eq(1)
    end

    # A first-time install into a brand-new org has no project match and no
    # existing installation row, so the resolver must defer to the active
    # `PendingInstallClaim` written by the install callback (state CSRF
    # verified or operator-authenticated) to identify the owning account.
    it "binds via an active PendingInstallClaim when no other signal matches" do
      PendingInstallClaim.upsert_for_callback!(
        account: account,
        installation_id: 88_777_777,
        source: "callback_with_state",
        state_token: "abc"
      )

      resolved = described_class.call(
        payload: installation_payload(installation_id: 88_777_777)
      )

      expect(resolved).to eq(account)
    end

    it "ignores an expired PendingInstallClaim" do
      PendingInstallClaim.upsert_for_callback!(
        account: account,
        installation_id: 88_777_777,
        source: "callback_with_state"
      )
      TenantContext.with_system_access do
        PendingInstallClaim.where(github_installation_id: 88_777_777)
          .update_all(expires_at: 1.hour.ago)
      end

      resolved = described_class.call(
        payload: installation_payload(installation_id: 88_777_777)
      )

      expect(resolved).to be_nil
    end

    it "returns nil when two accounts have an active claim for the same installation" do
      other_account = create(:account)
      PendingInstallClaim.upsert_for_callback!(
        account: account,
        installation_id: 88_777_777,
        source: "callback_with_state"
      )
      PendingInstallClaim.upsert_for_callback!(
        account: other_account,
        installation_id: 88_777_777,
        source: "callback_with_state"
      )

      resolved = described_class.call(
        payload: installation_payload(installation_id: 88_777_777)
      )

      expect(resolved).to be_nil
    end
  end
end
