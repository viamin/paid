# frozen_string_literal: true

require "rails_helper"

RSpec.describe StalledCloseoutProjectionSweepJob do # @spec PARTIAL-CLOSEOUT-042
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:project) do
    create(
      :project,
      account: account,
      created_by: user,
      auto_pick_enabled: true,
      active: true,
      auto_merge_mode: "all",
      owner_reviewer_login: "viamin",
      owner: "acme",
      repo: "alpha"
    )
  end

  before do
    allow(Rails.logger).to receive(:info)
    allow(described_class).to receive(:perform_later)
  end

  it "enqueues one recomputation per due flag-enabled project and chains to the next account" do
    FeatureFlags.enable!(Issues::StalledCloseoutProjection::FLAG, project: project)
    other_account = create(:account)

    described_class.perform_now

    expect(RecomputeStalledCloseoutProjectionJob).to have_been_enqueued.with(project.id)
    expect(described_class).to have_received(:perform_later).with(after_account_id: Account.active.order(:id).first.id)
    expect(other_account).to be_present
  end

  it "skips projects without a changed input and logs the sweep outcome" do
    FeatureFlags.enable!(Issues::StalledCloseoutProjection::FLAG, project: project)
    allow(Issues::StalledCloseoutProjection).to receive(:due_projects).and_return([])

    described_class.perform_now(after_account_id: account.id - 1)

    expect(RecomputeStalledCloseoutProjectionJob).not_to have_been_enqueued
    expect(Rails.logger).to have_received(:info).with(
      hash_including(message: "issues.stall_projection_sweep_completed", account_id: account.id, due_projects: 0)
    )
  end

  it "advances to the next account when one account's sweep fails instead of stalling the chain" do
    account
    allow(Issues::StalledCloseoutProjection).to receive(:due_projects).and_raise(ActiveRecord::StatementInvalid, "boom")
    allow(Rails.logger).to receive(:error)

    described_class.perform_now(after_account_id: account.id - 1)

    expect(Rails.logger).to have_received(:error).with(
      hash_including(message: "issues.stall_projection_sweep_failed", account_id: account.id)
    )
    expect(described_class).to have_received(:perform_later).with(after_account_id: account.id)
  end

  it "runs on maintenance with one fleet-wide scheduler invocation" do
    config = described_class.good_job_concurrency_config

    expect(described_class.queue_name).to eq("maintenance")
    expect(config).to include(enqueue_limit: 2, perform_limit: 1)
    expect(config).not_to have_key(:total_limit)
    expect(config[:key]).to eq("stalled_closeout_projection_sweep")
  end
end
