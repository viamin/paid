# frozen_string_literal: true

require "rails_helper"

RSpec.describe Issues::StalledCloseoutProjection do # @spec PARTIAL-CLOSEOUT-042
  include ActiveJob::TestHelper

  let(:account) { create(:account) }
  let(:project) { create(:project, account:) }

  before do
    FeatureFlags.enable!(:partial_closeout_lane_read_model, project:)
    clear_enqueued_jobs
  end

  it "enqueues initial recomputation when an existing project is enabled" do
    FeatureFlags.disable!(:partial_closeout_lane_read_model, project:)
    issue = create(:issue, project:, paid_state: "in_progress")
    create(:issue, :pull_request, project:, parent_issue_id: issue.id,
      github_state: "closed", pr_review_phase: "merged")
    clear_enqueued_jobs

    perform_enqueued_jobs do
      FeatureFlags.enable!(:partial_closeout_lane_read_model, project:)
    end

    checkpoint = project.reload.partial_closeout_projection
    expect(checkpoint.computed_at).to be_present
    expect(checkpoint.entries).to contain_exactly(have_attributes(issue_id: issue.id))
  end

  it "enqueues recomputation when an issue dependency changes" do
    issue = create(:issue, project:)
    dependency = create(:issue, project:)

    expect { create(:issue_dependency, issue:, depends_on_issue: dependency) }
      .to have_enqueued_job(RecomputePartialCloseoutProjectionJob).with(project.id)
  end

  it "enqueues recomputation when code-scanning admission evidence changes" do
    issue = create(:issue, project:)

    expect { create(:code_scanning_remediation_attempt, issue:) }
      .to have_enqueued_job(RecomputePartialCloseoutProjectionJob).with(project.id)
  end

  it "enqueues recomputation when a selected runner tier changes" do
    run = create(:agent_run, project:, issue: create(:issue, project:))

    expect { create(:model_selection, agent_run: run) }
      .to have_enqueued_job(RecomputePartialCloseoutProjectionJob).with(project.id)
  end

  it "enqueues recomputation only for admission-relevant AgentRun changes" do
    issue = create(:issue, project:)
    run = create(:agent_run, project:, issue:)
    clear_enqueued_jobs

    expect { run.touch }
      .not_to have_enqueued_job(RecomputePartialCloseoutProjectionJob)
    expect { run.update!(status: "running") }
      .to have_enqueued_job(RecomputePartialCloseoutProjectionJob).with(project.id)
  end

  it "enqueues recomputation when project admission inputs change" do
    changes = [
      { paused: true },
      { quality_paused_at: Time.current },
      { allowed_github_usernames: [ "trusted-operator" ] },
      { auto_pick_skip_labels: [ "held" ] }
    ]

    changes.each do |attributes|
      clear_enqueued_jobs
      expect { project.update!(attributes) }
        .to have_enqueued_job(RecomputePartialCloseoutProjectionJob).with(project.id)
    end
  end

  it "enqueues recomputation when feature-intent release state changes" do
    feature_intent = create(:feature_intent, project:)
    clear_enqueued_jobs

    expect { feature_intent.update!(status: "revising") }
      .to have_enqueued_job(RecomputePartialCloseoutProjectionJob).with(project.id)
  end

  it "enqueues recomputation when a prerequisite notification changes" do
    notification = create(:notification, account:, subject: create(:issue, project:),
      source: PartialCloseouts::PREREQUISITE_NOTIFICATION_SOURCE)
    clear_enqueued_jobs

    expect { notification.update!(resolved_at: Time.current) }
      .to have_enqueued_job(RecomputePartialCloseoutProjectionJob).with(project.id)
  end

  it "enqueues recomputation for the account's projects when runner feasibility changes" do
    user = create(:user, account:)
    clear_enqueued_jobs

    expect { create(:runner, user:) }
      .to have_enqueued_job(RecomputePartialCloseoutProjectionJob).with(project.id)
  end
end
