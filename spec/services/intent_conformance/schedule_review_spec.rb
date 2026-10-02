# frozen_string_literal: true

require "rails_helper"

# `not_change` matches RSpec's `change` matcher for compound expectations and
# is also used by several existing examples here; `not_have_enqueued_job`
# complements rspec-rails' `have_enqueued_job`. Defined locally so the file is
# self-contained.
RSpec::Matchers.define_negated_matcher :not_change, :change
RSpec::Matchers.define_negated_matcher :not_have_enqueued_job, :have_enqueued_job

# @spec INTENT-CONFORMANCE-010
RSpec.describe IntentConformance::ScheduleReview do
  include ActiveJob::TestHelper

  let(:project) { create(:project) }
  let(:issue) { create(:issue, :pull_request, project: project, github_number: 42) }
  let(:feature_intent) do
    create(:feature_intent, project: project, status: "released", approved_design_revision: "design-v1")
  end
  let(:head_sha) { "head-v1" }

  before do
    project.account.tenant_setting!.update!(features: { "approved_intent_amendments" => true })
    create(:feature_intent_issue, feature_intent: feature_intent, issue: issue)
  end

  after { clear_enqueued_jobs }

  def schedule
    described_class.call(project: project, issue: issue, pr_head_sha: head_sha)
  end

  def create_schedule(**attributes)
    create(:intent_conformance_review_schedule,
      project: project, issue: issue, pr_head_sha: head_sha,
      approved_design_revision: feature_intent.approved_design_revision, **attributes)
  end

  it "enqueues one review for an unreviewed released intent" do
    expect {
      schedule
    }.to change(IntentConformanceReviewSchedule, :count).by(1)
      .and have_enqueued_job(IntentConformance::ReviewJob)

    created = IntentConformanceReviewSchedule.last
    expect(created.pr_head_sha).to eq("head-v1")
    expect(created.approved_design_revision).to eq("design-v1")
    expect(created.enqueued_at).to be_present
  end

  it "does not enqueue a duplicate for repeated scans of the same identity" do
    schedule

    expect {
      schedule
    }.to not_change(IntentConformanceReviewSchedule, :count)
      .and not_have_enqueued_job(IntentConformance::ReviewJob)
  end

  it "schedules a fresh review when the head or approved design revision changes" do
    schedule
    feature_intent.update!(approved_design_revision: "design-v2")

    expect {
      described_class.call(project: project, issue: issue, pr_head_sha: "head-v2")
    }.to change(IntentConformanceReviewSchedule, :count).by(1)
  end

  it "does not schedule PRs without a released intent and approved revision" do
    feature_intent.update!(status: "revising", approved_design_revision: nil)

    expect {
      schedule
    }.to not_change(IntentConformanceReviewSchedule, :count)
      .and not_have_enqueued_job(IntentConformance::ReviewJob)
  end

  it "does not schedule when the project has not opted into the rollout flag" do
    project.account.tenant_setting!.update!(features: { "approved_intent_amendments" => false })

    expect {
      schedule
    }.to not_change(IntentConformanceReviewSchedule, :count)
      .and not_have_enqueued_job(IntentConformance::ReviewJob)
  end

  # @spec INTENT-CONFORMANCE-ROLLOUT-001
  it "schedules a shadow review without enabling the amendment or merge guard" do
    project.account.tenant_setting!.update!(features: { "intent_conformance_shadow_review" => true })

    expect {
      schedule
    }.to change(IntentConformanceReviewSchedule, :count).by(1)
      .and have_enqueued_job(IntentConformance::ReviewJob)
  end

  it "does not schedule when a verdict already exists for the exact identity" do
    create(:intent_conformance_verdict, project: project, issue: issue,
      pr_head_sha: head_sha, approved_design_revision: "design-v1")

    expect {
      schedule
    }.to not_change(IntentConformanceReviewSchedule, :count)
      .and not_have_enqueued_job(IntentConformance::ReviewJob)
  end

  it "does not schedule when the issue is not a pull request" do
    plain_issue = create(:issue, project: project)
    create(:feature_intent_issue, feature_intent: feature_intent, issue: plain_issue)

    expect {
      described_class.call(project: project, issue: plain_issue, pr_head_sha: head_sha)
    }.not_to change(IntentConformanceReviewSchedule, :count)
  end

  it "caps pending schedules per project" do
    other_issue = create(:issue, :pull_request, project: project)
    create_list(:intent_conformance_review_schedule, described_class::MAX_PENDING_PER_PROJECT,
      project: project, issue: other_issue, approved_design_revision: "design-v1")

    expect {
      schedule
    }.to not_change(IntentConformanceReviewSchedule, :count)
      .and not_have_enqueued_job(IntentConformance::ReviewJob)
  end

  it "re-enqueues a stale pending schedule whose job was lost" do
    existing = create_schedule(enqueued_at: 2.hours.ago)

    expect {
      schedule
    }.to have_enqueued_job(IntentConformance::ReviewJob)
      .and not_change(IntentConformanceReviewSchedule, :count)

    expect(existing.reload.enqueued_at).to be > 1.hour.ago
  end

  it "reactivates a completed schedule when no verdict was produced for the identity" do
    existing = create_schedule(status: "completed", completed_at: 1.hour.ago)

    expect {
      schedule
    }.to have_enqueued_job(IntentConformance::ReviewJob)
      .and not_change(IntentConformanceReviewSchedule, :count)

    expect(existing.reload).to be_pending
    expect(existing.reload.completed_at).to be_nil
  end

  it "does not re-enqueue a pending schedule whose job may still be running" do
    create_schedule(enqueued_at: 5.minutes.ago)

    expect {
      schedule
    }.not_to have_enqueued_job(IntentConformance::ReviewJob)
  end

  it "does not re-enqueue a fresh running schedule whose job may still be in-flight" do
    create_schedule(status: "running", enqueued_at: 5.minutes.ago)

    expect {
      schedule
    }.not_to have_enqueued_job(IntentConformance::ReviewJob)
  end

  it "recovers a stale running schedule whose perform was lost (timeout, crash, kill)" do
    existing = create_schedule(status: "running", enqueued_at: 2.hours.ago)

    expect {
      schedule
    }.to have_enqueued_job(IntentConformance::ReviewJob)
      .and not_change(IntentConformanceReviewSchedule, :count)

    expect(existing.reload).to be_pending
    expect(existing.reload.completed_at).to be_nil
    expect(existing.reload.enqueued_at).to be > 1.hour.ago
  end

  describe "structured logging" do
    it "logs the scheduling decision with correlation fields" do
      allow(Rails.logger).to receive(:info)

      schedule

      expect(Rails.logger).to have_received(:info).with(
        hash_including(
          message: "intent_conformance.review_scheduled",
          project_id: project.id,
          issue_id: issue.id,
          pr_head_sha: head_sha,
          approved_design_revision: "design-v1"
        )
      )
    end

    it "logs a warning when the per-project pending cap is reached" do
      allow(Rails.logger).to receive(:warn)
      other_issue = create(:issue, :pull_request, project: project)
      create_list(:intent_conformance_review_schedule, described_class::MAX_PENDING_PER_PROJECT,
        project: project, issue: other_issue, approved_design_revision: "design-v1")

      schedule

      expect(Rails.logger).to have_received(:warn).with(
        hash_including(
          message: "intent_conformance.review_schedule_capped",
          project_id: project.id,
          issue_id: issue.id,
          pr_head_sha: head_sha
        )
      )
    end
  end
end
