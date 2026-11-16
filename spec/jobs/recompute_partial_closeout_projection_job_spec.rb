# frozen_string_literal: true

require "rails_helper"

RSpec.describe RecomputePartialCloseoutProjectionJob do # @spec PARTIAL-CLOSEOUT-042
  it "coalesces queued and performing recomputations by project" do
    config = described_class.good_job_concurrency_config

    expect(config).to include(enqueue_limit: 1, perform_limit: 1)
    expect(described_class.new(123).good_job_concurrency_key)
      .to eq("partial_closeout_projection_123")
  end

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
