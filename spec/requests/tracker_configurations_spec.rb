# frozen_string_literal: true

require "rails_helper"

RSpec.describe "TrackerConfigurations" do
  describe "POST /tracker_configurations" do
    it "does not accept a sync cadence from an account member" do
      # @spec UNIFIED-WORK-ITEMS-002
      account = create(:account)
      create(:user, account:)
      member = create(:user, :member, account:)
      sign_in member

      post tracker_configurations_path, params: {
        tracker_configuration: {
          configurable_type: "Account",
          tracker_type: "linear",
          base_url: "https://linear.app",
          sync_interval_seconds: 300
        }
      }

      expect(response).to have_http_status(:created)
      expect(account.reload.tracker_configuration.sync_interval_seconds).to eq(900)
    end
  end
end
