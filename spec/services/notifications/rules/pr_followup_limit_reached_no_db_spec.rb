# frozen_string_literal: true

require "rails_helper"

RSpec.describe Notifications::Rules::PrFollowupLimitReached, :no_db do
  describe "::NO_PROGRESS_ESCALATION_WINDOW" do
    it "matches the PR scanner threshold" do
      expect(described_class::NO_PROGRESS_ESCALATION_WINDOW).to eq(
        Activities::ScanPaidPrsActivity::NO_PROGRESS_ESCALATION_WINDOW
      )
    end
  end
end
