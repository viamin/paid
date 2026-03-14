# frozen_string_literal: true

require "rails_helper"

RSpec.describe DashboardChannel, type: :channel do
  let(:user) { create(:user) }
  let(:account) { user.account }

  before do
    stub_connection current_user: user
  end

  describe "#subscribed" do
    it "streams for the user's account" do
      subscribe
      expect(subscription).to be_confirmed
      expect(subscription).to have_stream_for(account)
    end
  end
end
