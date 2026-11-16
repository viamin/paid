# frozen_string_literal: true

require "rails_helper"

RSpec.describe RecomputePartialCloseoutProjectionJob do # @spec PARTIAL-CLOSEOUT-042
  it "recomputes inside the project's owning tenant context" do
    account = create(:account)
    project = create(:project, account:)
    FeatureFlags.enable!(:partial_closeout_lane_read_model, project:)
    observed_account = nil
    callback = ->(*) { observed_account ||= Current.account }

    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
      described_class.perform_now(project.id)
    end

    expect(observed_account).to eq(account)
  end
end
