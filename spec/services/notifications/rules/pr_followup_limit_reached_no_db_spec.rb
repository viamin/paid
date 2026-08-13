# frozen_string_literal: true

require "rails_helper"

RSpec.describe Notifications::Rules::PrFollowupLimitReached, :no_db do
  describe "::REQUIRED_STUCK_CONFIRMATIONS" do
    it "matches the PR scanner threshold" do
      expect(described_class::REQUIRED_STUCK_CONFIRMATIONS).to eq(
        Activities::ScanPaidPrsActivity::REQUIRED_STUCK_CONFIRMATIONS
      )
    end
  end
end
