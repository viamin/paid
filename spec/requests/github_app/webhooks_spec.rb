# frozen_string_literal: true

require "rails_helper"

RSpec.describe "GithubApp::Webhooks", type: :request do
  let(:account) { create(:account) }
  let(:webhook_secret) { "shhh-shhh-shhh" }
  let(:webhook_url) { "/api/webhooks/github_app" }

  before do
    ENV["PAID_AGENT_APP_WEBHOOK_SECRET"] = webhook_secret
  end

  after do
    ENV.delete("PAID_AGENT_APP_WEBHOOK_SECRET")
  end

  def post_webhook(event:, payload:)
    body = payload.to_json
    signature = "sha256=#{OpenSSL::HMAC.hexdigest("SHA256", webhook_secret, body)}"
    post webhook_url,
      params: body,
      headers: {
        "Content-Type" => "application/json",
        "X-GitHub-Event" => event,
        "X-Hub-Signature-256" => signature
      }
  end

  let(:base_installation) do
    {
      "id" => 88_777_777,
      "account" => { "login" => "acme-corp" },
      "target_type" => "Organization",
      "repository_selection" => "all",
      "repositories" => [
        { "id" => 1, "full_name" => "acme-corp/widgets", "name" => "widgets",
          "owner" => { "login" => "acme-corp" }, "default_branch" => "main" }
      ]
    }
  end

  describe "signature verification" do
    it "rejects requests without a signature" do
      post webhook_url,
        params: {}.to_json,
        headers: { "Content-Type" => "application/json", "X-GitHub-Event" => "installation" }

      expect(response).to have_http_status(:unauthorized)
    end

    it "rejects requests with an invalid signature" do
      post webhook_url,
        params: {}.to_json,
        headers: {
          "Content-Type" => "application/json",
          "X-GitHub-Event" => "installation",
          "X-Hub-Signature-256" => "sha256=#{'a' * 64}"
        }

      expect(response).to have_http_status(:unauthorized)
    end

    it "rejects requests when the webhook secret is not configured" do
      ENV.delete("PAID_AGENT_APP_WEBHOOK_SECRET")
      post webhook_url,
        params: {}.to_json,
        headers: {
          "Content-Type" => "application/json",
          "X-GitHub-Event" => "installation",
          "X-Hub-Signature-256" => "sha256=#{'a' * 64}"
        }

      expect(response).to have_http_status(:unauthorized)
    end
  end

  describe "installation.created" do
    it "creates a GithubInstallation tied to the existing record's account" do
      existing = create(:github_installation, account: account,
                        github_installation_id: 88_777_777,
                        account_login: "old-login")

      post_webhook(
        event: "installation",
        payload: { "action" => "created", "installation" => base_installation }
      )

      expect(response).to have_http_status(:ok)
      expect(existing.reload.account_login).to eq("acme-corp")
      expect(existing.accessible_repositories.first["full_name"]).to eq("acme-corp/widgets")
    end

    it "ignores events for unknown installations" do
      post_webhook(
        event: "installation",
        payload: { "action" => "created", "installation" => base_installation.merge("id" => 999) }
      )

      expect(response).to have_http_status(:ok)
    end
  end

  describe "installation.suspend" do
    it "marks the installation suspended" do
      existing = create(:github_installation, account: account,
                        github_installation_id: 88_777_777)

      post_webhook(
        event: "installation",
        payload: { "action" => "suspend", "installation" => base_installation }
      )

      expect(existing.reload.suspended_at).to be_present
    end
  end

  describe "installation.deleted" do
    it "marks the installation revoked" do
      existing = create(:github_installation, account: account,
                        github_installation_id: 88_777_777)

      post_webhook(
        event: "installation",
        payload: { "action" => "deleted", "installation" => base_installation }
      )

      expect(existing.reload.revoked_at).to be_present
    end
  end

  describe "installation_repositories events" do
    let!(:installation) do
      create(:github_installation, account: account,
             github_installation_id: 88_777_777,
             accessible_repositories: [
               { "id" => 1, "full_name" => "acme-corp/widgets", "name" => "widgets",
                 "owner" => "acme-corp", "default_branch" => "main" }
             ])
    end

    it "merges repositories on installation_repositories.added" do
      post_webhook(
        event: "installation_repositories",
        payload: {
          "action" => "added",
          "installation" => { "id" => 88_777_777 },
          "repositories_added" => [
            { "id" => 2, "full_name" => "acme-corp/gadgets", "name" => "gadgets",
              "owner" => { "login" => "acme-corp" }, "default_branch" => "main" }
          ]
        }
      )

      expect(installation.reload.accessible_repositories.map { |r| r["full_name"] })
        .to contain_exactly("acme-corp/widgets", "acme-corp/gadgets")
    end

    it "removes repositories on installation_repositories.removed" do
      post_webhook(
        event: "installation_repositories",
        payload: {
          "action" => "removed",
          "installation" => { "id" => 88_777_777 },
          "repositories_removed" => [
            { "id" => 1, "full_name" => "acme-corp/widgets" }
          ]
        }
      )

      expect(installation.reload.accessible_repositories).to be_empty
    end
  end

  describe "unknown events" do
    it "responds ok and does not touch installations" do
      post_webhook(event: "ping", payload: { "zen" => "Speak like a human" })

      expect(response).to have_http_status(:ok)
    end
  end
end