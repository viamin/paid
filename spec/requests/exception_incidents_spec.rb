# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Exception incidents" do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }

  before { sign_in user }

  describe "GET /exception_incidents" do
    it "renders both allowlisted and filing-blocked buckets with correct labels" do
      create(:exception_incident, account: account,
        subsystem: "knowledge", action_taken: "issue_filed",
        exception_class: "KnowledgeError", message: "indexed a bad doc")
      create(:exception_incident, account: account,
        subsystem: "github_sync", action_taken: "notified",
        exception_class: "SyncError", message: "webhook delivery failed")

      get exception_incidents_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("KnowledgeError")
      expect(response.body).to include("SyncError")
      expect(response.body).to include("On allowlist")
      expect(response.body).to include("Filing blocked")
    end

    it "scopes incidents to the current account" do
      create(:exception_incident, account: create(:account),
        subsystem: "general", action_taken: "notified",
        exception_class: "OtherAccountError")

      get exception_incidents_path

      expect(response.body).not_to include("OtherAccountError")
    end

    it "filters to filing-blocked incidents when requested" do
      create(:exception_incident, account: account,
        subsystem: "general", action_taken: "notified",
        exception_class: "BlockedError")
      create(:exception_incident, account: account,
        subsystem: "knowledge", action_taken: "issue_filed",
        exception_class: "FiledError")

      get exception_incidents_path(filter: "filing_blocked")

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("BlockedError")
      expect(response.body).not_to include("FiledError")
    end

    it "reflects live allowlist changes in the dashboard without caching" do
      create(:exception_incident, account: account,
        subsystem: "github_sync", action_taken: "notified",
        exception_class: "SyncError")

      get exception_incidents_path
      expect(response.body).to include("Filing blocked")

      stub_const("ExceptionHandler::Classifier::ISSUE_FILING_ALLOWLIST", %w[github_sync])

      get exception_incidents_path
      expect(response.body).to include("On allowlist")
    end
  end
end
