# frozen_string_literal: true

require "rails_helper"

RSpec.describe Tools::ListConfigurationProfiles do
  let(:account) { create(:account) }
  let(:user) { create(:user, account:) }
  let(:session) { create(:chat_session, account:, created_by: user) }

  it "returns the registered profile summaries" do
    result = described_class.new(user:, session:).call

    expect(result[:profiles]).to match([
      hash_including(profile_id: "solo_automated", name: "Solo Automated"),
      hash_including(profile_id: "team_reviewed", name: "Team Reviewed"),
      hash_including(profile_id: "observe_only", name: "Observe Only"),
      hash_including(profile_id: "manual_on_label", name: "Manual On Label"),
      hash_including(profile_id: "cost_capped_automated", name: "Cost Capped Automated"),
      hash_including(profile_id: "quality_strict", name: "Quality Strict")
    ])
  end
end
