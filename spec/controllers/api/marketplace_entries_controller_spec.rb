# frozen_string_literal: true

require "rails_helper"

RSpec.describe Api::MarketplaceEntriesController, type: :request do
  let(:account) { create(:account) }
  let(:user) { create(:user, :admin, account: account) }

  describe "GET /api/marketplace_entries" do
    before do
      sign_in user
    end

    it "returns active catalog entries by default" do
      active_entry = create_catalog_entry(
        name: "SOX Policy Pack",
        entry_type: "policy_pack",
        extension_points: [ "policies", "prompts" ],
        certification_status: "certified"
      )
      draft_entry = create(:marketplace_entry, account: account, status: "draft")
      create(:marketplace_entry, account: create(:account), name: "Other Account Entry")

      get "/api/marketplace_entries"

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.fetch("entries")).to contain_exactly(
        include(
          "id" => active_entry.id,
          "name" => "SOX Policy Pack",
          "entry_type" => "policy_pack",
          "extension_points" => %w[policies prompts],
          "certification_status" => "certified"
        )
      )
      expect(response.parsed_body.fetch("entries").map { |entry| entry["id"] }).not_to include(draft_entry.id)
    end

    it "filters by ecosystem metadata" do
      matching_entry = create_workflow_entry
      create_prompt_entry

      get "/api/marketplace_entries", params: workflow_filter_params

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.fetch("entries")).to contain_exactly(
        include("id" => matching_entry.id, "name" => "Workflow Kit")
      )
    end

    it "returns JSON unauthorized for unauthenticated requests" do
      sign_out user

      get "/api/marketplace_entries"

      expect(response).to have_http_status(:unauthorized)
      expect(response.parsed_body).to eq("error" => "Unauthorized")
    end
  end

  describe "GET /api/marketplace_entries/:id" do
    before do
      sign_in user
    end

    it "returns full catalog metadata for a single entry" do
      entry = create_integration_entry
      version = create_catalog_version(entry)
      entry.update!(current_version: version)
      create_automatic_rule(entry)

      get "/api/marketplace_entries/#{entry.id}"

      expect(response).to have_http_status(:ok)
      body = response.parsed_body
      expect(body["id"]).to eq(entry.id)
      expect(body["extension_points"]).to eq(%w[integrations tools])
      expect(body.dig("current_version", "canonical_artifact")).to eq("content" => "Install the connector")
      expect(body.fetch("rules")).to include(
        include(
          "mode" => "automatic",
          "enabled" => true,
          "conditions" => { "project_tags" => [ "connector" ] }
        )
      )
    end

    it "returns JSON not found for entries outside the policy scope" do
      other_account_entry = create(:marketplace_entry, account: create(:account))

      get "/api/marketplace_entries/#{other_account_entry.id}"

      expect(response).to have_http_status(:not_found)
      expect(response.parsed_body).to eq("error" => "Not found")
    end

    it "returns JSON not found for missing entries" do
      get "/api/marketplace_entries/0"

      expect(response).to have_http_status(:not_found)
      expect(response.parsed_body).to eq("error" => "Not found")
    end

    it "returns JSON unauthorized for unauthenticated requests" do
      sign_out user
      entry = create_integration_entry

      get "/api/marketplace_entries/#{entry.id}"

      expect(response).to have_http_status(:unauthorized)
      expect(response.parsed_body).to eq("error" => "Unauthorized")
    end
  end

  def create_catalog_entry(**attributes)
    create(:marketplace_entry, { account: account }.merge(attributes))
  end

  def create_workflow_entry
    create_catalog_entry(
      name: "Workflow Kit",
      entry_type: "workflow_strategy",
      extension_points: [ "workflow_strategies" ],
      certification_status: "verified",
      tags: [ "ecosystem", "workflow" ]
    )
  end

  def create_prompt_entry
    create_catalog_entry(
      name: "Prompt Kit",
      entry_type: "prompt_pack",
      extension_points: [ "prompts" ],
      certification_status: "verified",
      tags: [ "ecosystem" ]
    )
  end

  def create_integration_entry
    create_catalog_entry(
      entry_type: "integration",
      extension_points: [ "integrations", "tools" ],
      certification_status: "verified"
    )
  end

  def create_catalog_version(entry)
    create(:marketplace_entry_version,
      marketplace_entry: entry,
      canonical_artifact: { "content" => "Install the connector" },
      renderers: { "openai" => { "content" => "Rendered" } },
      compatibility_constraints: { "runner" => [ "codex" ] },
      review_metadata: { "checklist" => [ "docs", "rollback" ] })
  end

  def create_automatic_rule(entry)
    create(:marketplace_entry_rule,
      marketplace_entry: entry,
      mode: "automatic",
      enabled: true,
      rationale: "Attach for connector-enabled projects",
      conditions: { "project_tags" => [ "connector" ] })
  end

  def workflow_filter_params
    {
      entry_type: "workflow_strategy",
      extension_point: "workflow_strategies",
      certification_status: "verified",
      tag: "workflow"
    }
  end
end
