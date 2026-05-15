# frozen_string_literal: true

require "rails_helper"

RSpec.describe "MarketplaceEntries" do
  let(:account) { create(:account) }
  let(:user) { create(:user, :member, account: account) }

  before { sign_in user }

  describe "GET /marketplace_entries" do
    it "renders the index" do
      get marketplace_entries_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Marketplace Entries")
    end

    it "paginates entries" do
      21.times do |index|
        create(:marketplace_entry, account: account, name: format("Entry %03d", index + 1))
      end

      get marketplace_entries_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Entry 021")
      expect(response.body).not_to include("Entry 001")

      get marketplace_entries_path(page: 2)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Entry 001")
    end
  end

  describe "POST /marketplace_entries" do
    let(:params) do
      {
        marketplace_entry: {
          name: "Repo coding skill",
          entry_type: "skill",
          description: "Reusable coding instructions",
          provider: "claude",
          provider_format: "canonical_v1",
          usage_guidance: "Use on Rails issue runs.",
          tags_csv: "rails, repo",
          team_scope: "account",
          status: "active",
          canonical_artifact_json: JSON.generate(
            attachment_strategy: "prompt_append",
            content: "Follow the repo conventions."
          ),
          renderers_json: JSON.generate(
            claude: {
              attachment_strategy: "prompt_append",
              provider_format: "claude_skill_v1",
              content: "Use the Claude-native repo skill."
            }
          ),
          compatibility_constraints_json: JSON.generate(
            provider_keys: [ "claude" ],
            goals: [ "create_pr" ]
          ),
          review_metadata_json: JSON.generate(
            approved_by: "Lead",
            reviewed_at: "2026-05-14T00:00:00Z"
          ),
          automatic_enabled: "1",
          automatic_conditions_json: JSON.generate(goals: [ "create_pr" ]),
          automatic_rationale: "Attach on implementation runs",
          team_default_enabled: "1",
          team_default_conditions_json: JSON.generate({}),
          team_default_rationale: "Team baseline"
        }
      }
    end

    it "creates an entry and version for members without allowing rule changes" do
      expect {
        post marketplace_entries_path, params: params
      }.to change(MarketplaceEntry, :count).by(1)
        .and change(MarketplaceEntryVersion, :count).by(1)

      entry = MarketplaceEntry.last
      expect(MarketplaceEntryRule.count).to eq(0)
      expect(entry.current_version).to be_present
      expect(entry.current_version.renderers.fetch("claude").fetch("provider_format")).to eq("claude_skill_v1")
      expect(response).to redirect_to(marketplace_entry_path(entry))
    end

    it "creates rules for admins" do
      admin = create(:user, :admin, account: account)
      sign_out user
      sign_in admin

      expect {
        post marketplace_entries_path, params: params
      }.to change(MarketplaceEntry, :count).by(1)
        .and change(MarketplaceEntryVersion, :count).by(1)
        .and change(MarketplaceEntryRule, :count).by(2)
    end

    it "rejects entry types that are not wired into the runtime in this iteration" do
      invalid_params = params.deep_dup
      invalid_params[:marketplace_entry][:entry_type] = "plugin"

      expect {
        post marketplace_entries_path, params: invalid_params
      }.not_to change(MarketplaceEntry, :count)

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include("Entry type is not included in the list")
    end
  end
end
