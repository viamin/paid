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

  it "enqueues recomputation when an analysis backoff expires without a row change" do
    project = create(:project)
    issue = create(:issue, project:, issue_analysis_next_attempt_at: 5.minutes.from_now,
      issue_analysis_backoff_set_at: Time.current)
    FeatureFlags.enable!(:partial_closeout_lane_read_model, project:)
    Issues::StalledCloseoutProjection.call(project:)
    original_updated_at = issue.reload.updated_at
    clear_enqueued_jobs

    travel 6.minutes do
      expect { described_class.perform_now }
        .to have_enqueued_job(RecomputePartialCloseoutProjectionJob).with(project.id)
    end

    expect(issue.reload.updated_at).to eq(original_updated_at)
  end

  it "enqueues recomputation when the unsynced-PR grace period expires without a row change" do
    project = create(:project)
    issue = create(:issue, project:)
    run = create(:agent_run, project:, issue:, goal: "create_pr", status: "completed",
      pull_request_number: 999, completed_at: 30.minutes.ago)
    FeatureFlags.enable!(:partial_closeout_lane_read_model, project:)
    Issues::StalledCloseoutProjection.call(project:)
    original_updated_at = run.reload.updated_at
    clear_enqueued_jobs

    travel 31.minutes do
      expect { described_class.perform_now }
        .to have_enqueued_job(RecomputePartialCloseoutProjectionJob).with(project.id)
    end

    expect(run.reload.updated_at).to eq(original_updated_at)
  end
end
