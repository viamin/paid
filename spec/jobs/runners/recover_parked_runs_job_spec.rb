# frozen_string_literal: true

require "rails_helper"

RSpec.describe Runners::RecoverParkedRunsJob do
  include ActiveJob::TestHelper

  let(:user) { create(:user) }
  let(:project) { create(:project, account: user.account, created_by: user) }
  let(:issue) { create(:issue, project: project) }

  around do |example|
    original_adapter = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :test
    clear_enqueued_jobs
    clear_performed_jobs
    example.run
  ensure
    clear_enqueued_jobs
    clear_performed_jobs
    ActiveJob::Base.queue_adapter = original_adapter
  end

  it "makes the user's parked rate_limited runs due and enqueues the stale detector" do
    parked = create(:agent_run, :rate_limited, project: project, issue: issue,
      rate_limited_until: 2.days.from_now)

    described_class.perform_now(user.id)

    parked.reload
    expect(parked.rate_limited_until).to be <= Time.current
    expect(StaleRunDetectorJob).to have_been_enqueued
  end

  it "does not enqueue the stale detector when there are no parked runs" do
    described_class.perform_now(user.id)

    expect(StaleRunDetectorJob).not_to have_been_enqueued
  end

  it "ignores parked runs belonging to other accounts" do
    other_user = create(:user)
    other_project = create(:project, account: other_user.account, created_by: other_user)
    other_issue = create(:issue, project: other_project)
    other = create(:agent_run, :rate_limited, project: other_project, issue: other_issue,
      rate_limited_until: 2.days.from_now)
    original_reset = other.rate_limited_until

    described_class.perform_now(user.id)

    expect(other.reload.rate_limited_until).to eq(original_reset)
  end

      it "leaves already-due runs untouched and does not re-queue" do
        due = create(:agent_run, :rate_limited, project: project, issue: issue,
          rate_limited_until: 5.minutes.ago)

        described_class.perform_now(user.id)

        # already due — excluded from the update (only future resets advance);
        # no runs were advanced so the stale detector is not enqueued
        expect(due.reload.rate_limited_until.to_i).to eq(5.minutes.ago.to_i)
        expect(StaleRunDetectorJob).not_to have_been_enqueued
      end

  describe "Runner availability callback" do
    it "enqueues recovery when a runner is created" do
      user # create user (its default runner also enqueues; ignore that)
      clear_enqueued_jobs

      expect {
        create(:runner, user: user, runner_key: "codex", auth_type: "subscription")
      }.to have_enqueued_job(described_class).with(user.id)
    end

    it "enqueues recovery when a runner is re-enabled for agent runs" do
      runner = create(:runner, user: user, runner_key: "codex", auth_type: "subscription",
        enabled_for_agent_runs: false)
      clear_enqueued_jobs

      expect {
        runner.update!(enabled_for_agent_runs: true)
      }.to have_enqueued_job(described_class).with(user.id)
    end

    it "enqueues recovery when a runner is undiscarded" do
      runner = create(:runner, user: user, runner_key: "codex", auth_type: "subscription")
      runner.discard!
      clear_enqueued_jobs

      expect {
        runner.undiscard!
      }.to have_enqueued_job(described_class).with(user.id)
    end

    it "does not enqueue recovery when a runner is disabled for agent runs" do
      runner = create(:runner, user: user, runner_key: "codex", auth_type: "subscription")
      clear_enqueued_jobs

      expect {
        runner.update!(enabled_for_agent_runs: false)
      }.not_to have_enqueued_job(described_class)
    end

    it "does not enqueue recovery on an unrelated runner update" do
      runner = create(:runner, user: user, runner_key: "codex", auth_type: "subscription")
      clear_enqueued_jobs

      expect {
        runner.update!(weight: 5)
      }.not_to have_enqueued_job(described_class)
    end
  end
end
