# frozen_string_literal: true

require "rails_helper"

RSpec.describe MainCiSweepJob do
  include ActiveJob::TestHelper

  # @spec MAIN-CI-001 MAIN-CI-007
  it "polls only active opted-in projects through the existing queue" do
    enabled = create(:project, review_settings: { "main_ci_recovery" => { "enabled" => true,
      "required_workflows" => [ ".github/workflows/ci.yml" ], "executor_revision" => "e" * 40 } })
    create(:project)
    expect { described_class.perform_now }.to have_enqueued_job(MainCiReconciliationJob).with(enabled.id).exactly(:once)
  end
end
