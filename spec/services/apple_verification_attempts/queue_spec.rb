# frozen_string_literal: true

require "rails_helper"

# @spec APPLE-ATTEMPT-003
RSpec.describe AppleVerificationAttempts::Queue do
  let(:account_a) { create(:account) }
  let(:account_b) { create(:account) }
  let(:account_a_first_project) { create(:project, account: account_a) }
  let(:account_a_second_project) { create(:project, account: account_a) }
  let(:account_b_first_project) { create(:project, account: account_b) }

  def queued_attempt_for(project:, account: project.account, status: "queued", created_at: Time.current)
    create(
      :apple_verification_attempt,
      project: project,
      account: account,
      status: status,
      created_at: created_at
    )
  end

  it "interleaves queued attempts across projects within an account and assigns 1-based positions" do
    older = queued_attempt_for(project: account_a_first_project, created_at: 2.minutes.ago)
    newer = queued_attempt_for(project: account_a_first_project, created_at: 1.minute.ago)
    queued_attempt_for(project: account_a_second_project, created_at: 1.minute.ago)

    entries = described_class.call(account_scope: account_a)

    expect(entries.first.project_id).to eq(account_a_first_project.id)
    expect(entries.first.attempt.id).to eq(older.id)
    expect(entries.first.position).to eq(1)
    expect(entries.second.project_id).to eq(account_a_second_project.id)
    expect(entries.third.project_id).to eq(account_a_first_project.id)
    expect(entries.third.attempt.id).to eq(newer.id)
  end

  it "round-robins accounts before selecting another project for an account" do
    queued_attempt_for(project: account_a_first_project)
    queued_attempt_for(project: account_a_second_project)
    queued_attempt_for(project: account_b_first_project, account: account_b)

    entries = described_class.call

    project_ids_in_order = entries.first(3).map(&:project_id)
    expect(project_ids_in_order).to eq([
      account_a_first_project.id,
      account_b_first_project.id,
      account_a_second_project.id
    ])
    expect(entries.first(3).map(&:position)).to eq([ 1, 2, 3 ])
  end

  it "excludes attempts that are already running or terminal" do
    queued_attempt_for(project: account_a_first_project)
    running = queued_attempt_for(project: account_a_first_project, status: "running")
    terminal = queued_attempt_for(project: account_a_first_project, status: "succeeded")

    entries = described_class.call(account_scope: account_a)

    expect(entries.map(&:attempt)).not_to include(running, terminal)
  end

  it "exposes queue position for a specific attempt" do
    first = queued_attempt_for(project: account_a_first_project, created_at: 2.minutes.ago)
    second = queued_attempt_for(project: account_a_first_project, created_at: 1.minute.ago)
    third = queued_attempt_for(project: account_a_second_project)

    queue = described_class.new(account_scope: account_a)

    # Round-robin order: a1 (oldest), a2, a1 (newest). So `first` is 1,
    # `third` is 2, `second` is 3.
    expect(queue.position_for(first)).to eq(1)
    expect(queue.position_for(third)).to eq(2)
    expect(queue.position_for(second)).to eq(3)
    terminal = create(:apple_verification_attempt, project: account_a_first_project, account: account_a, status: "succeeded")
    expect(queue.position_for(terminal)).to be_nil
  end

  it "cancels a queued attempt and raises for non-queued attempts" do
    attempt = queued_attempt_for(project: account_a_first_project)

    described_class.new(account_scope: account_a).cancel(attempt)

    expect(attempt.reload.status).to eq("cancelled")
    expect(attempt.finished_at).to be_present

    terminal = create(:apple_verification_attempt, project: account_a_first_project, account: account_a, status: "succeeded")

    expect {
      described_class.new(account_scope: account_a).cancel(terminal)
    }.to raise_error(AppleVerificationAttempts::Queue::NotQueuedError)
  end

  it "reports operator-configurable queue limits" do
    queue = described_class.new(
      queue_depth_limit: 50,
      max_attempts_per_run: 8,
      max_runtime_minutes: 90,
      retained_storage_hours: 6
    )

    expect(queue.queue_depth_limit).to eq(50)
    expect(queue.max_attempts_per_run).to eq(8)
    expect(queue.max_runtime_minutes).to eq(90)
    expect(queue.retained_storage_hours).to eq(6)
  end
end
