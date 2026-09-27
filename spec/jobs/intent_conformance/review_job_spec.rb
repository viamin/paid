# frozen_string_literal: true

require "rails_helper"

# @spec INTENT-CONFORMANCE-011
RSpec.describe IntentConformance::ReviewJob do
  let(:project) { create(:project) }
  let(:issue) { create(:issue, :pull_request, project: project, github_number: 42) }
  let(:feature_intent) do
    create(:feature_intent, project: project, status: "released", approved_design_revision: "design-v1")
  end
  let(:schedule) do
    create(:intent_conformance_review_schedule,
      project: project, issue: issue, pr_head_sha: "head-v1", approved_design_revision: "design-v1")
  end

  before do
    project.account.tenant_setting!.update!(features: { "approved_intent_amendments" => true })
    create(:feature_intent_issue, feature_intent: feature_intent, issue: issue)
  end

  # ReviewRun persists its verdict inside #call, so the stub creates the
  # record lazily at call time — a verdict persisted before perform_now would
  # trip the job's existing-verdict short-circuit before the review ever runs.
  # verdict_traits: nil models a run that is no longer applicable (call
  # returns nil and persists nothing).
  def stub_review_run(verdict_traits: [], failure_reason: nil)
    allow(IntentConformance::ReviewRun).to receive(:new) do
      verdict = verdict_traits && create(:intent_conformance_verdict, *verdict_traits, project: project, issue: issue,
        pr_head_sha: "head-v1", approved_design_revision: "design-v1")
      instance_double(IntentConformance::ReviewRun, call: verdict, failure_reason: failure_reason)
    end
  end

  def current_verdict
    IntentConformanceVerdict.current_for(issue: issue, head_sha: "head-v1")
  end

  it "records a completed schedule after a review verdict" do
    stub_review_run

    described_class.perform_now(project.id, schedule.id)

    expect(schedule.reload).to be_completed
    expect(schedule.reload.attempts_count).to eq(1)
    expect(schedule.reload.last_failure_reason).to be_nil
    expect(IntentConformance::ReviewRun).to have_received(:new)
      .with(project: project, issue: issue, pr_head_sha: "head-v1")
  end

  it "marks the schedule completed without a new review when the identity already has a terminal verdict" do
    create(:intent_conformance_verdict, project: project, issue: issue,
      pr_head_sha: "head-v1", approved_design_revision: "design-v1")

    expect(IntentConformance::ReviewRun).not_to receive(:new)

    described_class.perform_now(project.id, schedule.id)

    expect(schedule.reload).to be_completed
  end

  it "leaves a classified business failure fail-closed without retrying" do
    stub_review_run(verdict_traits: [ :not_evaluated ], failure_reason: "issue_untrusted")

    expect { described_class.perform_now(project.id, schedule.id) }.not_to have_enqueued_job(described_class)

    expect(schedule.reload).to be_completed
    expect(schedule.reload.last_failure_reason).to eq("issue_untrusted")
    expect(current_verdict).to be_not_evaluated
  end

  it "fails closed for an empty design-document list without retrying" do
    stub_review_run(verdict_traits: [ :not_evaluated ], failure_reason: "no_design_documents")

    expect { described_class.perform_now(project.id, schedule.id) }.not_to have_enqueued_job(described_class)

    expect(schedule.reload).to be_completed
    expect(schedule.reload.last_failure_reason).to eq("no_design_documents")
  end

  it "retries a transient reviewer failure with framework backoff" do
    stub_review_run(verdict_traits: [ :not_evaluated ], failure_reason: "unsuccessful_response")

    expect { described_class.perform_now(project.id, schedule.id) }
      .to have_enqueued_job(described_class).with(project.id, schedule.id)

    expect(schedule.reload).to be_pending
    expect(schedule.reload.attempts_count).to eq(1)
    expect(current_verdict).to be_not_evaluated
  end

  it "retries a missing diff as a transient failure" do
    stub_review_run(verdict_traits: [ :not_evaluated ], failure_reason: "no_diff")

    expect { described_class.perform_now(project.id, schedule.id) }
      .to have_enqueued_job(described_class).with(project.id, schedule.id)
  end

  it "re-runs the review on retry instead of short-circuiting on the failed attempt's not_evaluated verdict" do
    stub_review_run(verdict_traits: [ :not_evaluated ], failure_reason: "unsuccessful_response")

    expect { described_class.perform_now(project.id, schedule.id) }
      .to have_enqueued_job(described_class).with(project.id, schedule.id)

    # GoodJob retry: the not_evaluated verdict the failed attempt persisted is
    # not terminal, so the retry must execute the review again rather than
    # completing the schedule on that stale verdict.
    expect { described_class.perform_now(project.id, schedule.id) }
      .to have_enqueued_job(described_class).with(project.id, schedule.id)

    expect(IntentConformance::ReviewRun).to have_received(:new).twice
    expect(schedule.reload).to be_pending
    expect(schedule.reload.attempts_count).to eq(2)
  end

  it "marks the schedule completed once bounded retries are exhausted, keeping the fail-closed verdict" do
    stub_review_run(verdict_traits: [ :not_evaluated ], failure_reason: "unsuccessful_response")
    described_class.perform_now(project.id, schedule.id)

    described_class.new(project.id, schedule.id).on_retries_exhausted(
      IntentConformance::ReviewJob::TransientReviewError.new("unsuccessful_response")
    )

    expect(schedule.reload).to be_completed
    expect(schedule.reload.last_failure_reason).to eq("unsuccessful_response")
    expect(current_verdict).to be_not_evaluated
  end

  it "marks the schedule completed without review when the run is no longer applicable" do
    stub_review_run(verdict_traits: nil)

    expect { described_class.perform_now(project.id, schedule.id) }.not_to raise_error

    expect(schedule.reload).to be_completed
  end

  it "emits a structured completion log with correlation fields" do
    allow(Rails.logger).to receive(:info)
    stub_review_run

    described_class.perform_now(project.id, schedule.id)

    expect(Rails.logger).to have_received(:info).with(
      hash_including(
        message: "intent_conformance.review_completed",
        project_id: project.id,
        issue_id: issue.id,
        pr_head_sha: "head-v1",
        approved_design_revision: "design-v1",
        outcome: "within_scope"
      )
    )
  end

  it "uses a bounded per-project concurrency key" do
    expect(described_class.good_job_concurrency_config).to include(total_limit: 2, enqueue_limit: 8)
    expect(described_class.new(project.id, schedule.id).good_job_concurrency_key)
      .to eq("intent_conformance_review_project_#{project.id}")
  end
end
