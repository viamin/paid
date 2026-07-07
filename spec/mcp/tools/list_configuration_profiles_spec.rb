# frozen_string_literal: true

require "rails_helper"

RSpec.describe Tools::ListConfigurationProfiles do
  let(:account) { create(:account) }
  let(:user) { create(:user, account:) }
  let(:session) { create(:chat_session, account:, created_by: user) }

  it "returns the registered profile summaries" do
    result = described_class.new(user:, session:).call

    expect(result[:profiles]).to include(
      hash_including(id: "solo_fully_automated", levels: contain_exactly(:user, :tenant)),
      hash_including(id: "team_collaborative", levels: contain_exactly(:user, :tenant))
    )
  end
end
