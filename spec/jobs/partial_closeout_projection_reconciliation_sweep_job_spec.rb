# frozen_string_literal: true

require "rails_helper"

RSpec.describe PartialCloseoutProjectionReconciliationSweepJob do # @spec PARTIAL-CLOSEOUT-042
  include ActiveJob::TestHelper

  it "enqueues recomputation when admission inputs changed without a callback" do
    project = create(:project)
    issue = create(:issue, project:)
    FeatureFlags.enable!(:partial_closeout_lane_read_model, project:)
    Issues::StalledCloseoutProjection.call(project:)
    clear_enqueued_jobs

    issue.update_columns(updated_at: 1.minute.from_now)

    expect { described_class.perform_now }
      .to have_enqueued_job(RecomputePartialCloseoutProjectionJob).with(project.id)
  end

  it "enqueues recomputation when a lost delete callback leaves the latest timestamp unchanged" do
    project = create(:project)
    older_issue = create(:issue, project:, updated_at: 2.minutes.ago)
    create(:issue, project:, updated_at: 1.minute.ago)
    FeatureFlags.enable!(:partial_closeout_lane_read_model, project:)
    Issues::StalledCloseoutProjection.call(project:)

    older_issue.destroy!
    clear_enqueued_jobs

    expect { described_class.perform_now }
      .to have_enqueued_job(RecomputePartialCloseoutProjectionJob).with(project.id)
  end

  it "enqueues recomputation for an enabled project without a successful checkpoint" do
    project = create(:project)
    FeatureFlags.enable!(:partial_closeout_lane_read_model, project:)
    clear_enqueued_jobs

    expect { described_class.perform_now }
      .to have_enqueued_job(RecomputePartialCloseoutProjectionJob).with(project.id)
  end

  it "does not enqueue recomputation for a current checkpoint" do
    project = create(:project)
    FeatureFlags.enable!(:partial_closeout_lane_read_model, project:)
    Issues::StalledCloseoutProjection.call(project:)
    clear_enqueued_jobs

    expect { described_class.perform_now }
      .not_to have_enqueued_job(RecomputePartialCloseoutProjectionJob)
  end
end
