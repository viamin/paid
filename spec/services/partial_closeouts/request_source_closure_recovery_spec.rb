# frozen_string_literal: true

require "rails_helper"

RSpec.describe PartialCloseouts::RequestSourceClosureRecovery do
  let(:account) { create(:account) }
  let(:user) { create(:user, account:) }
  let(:project) { create(:project, account:) }
  let(:run) { create(:agent_run, project:, status: "waiting_recovery", branch_name: "paid/source-closure", result_commit_sha: "a" * 40) }

  # @spec PARTIAL-CLOSEOUT-065
  it "records the accepted request with pinned source identity and queue provenance" do
    result = described_class.call(agent_run: run, actor: user, boundary: "mcp")

    expect(result).to be_queued
    event = AccountActivityEvent.last
    expect(event).to have_attributes(
      account: account,
      actor: user,
      subject: run,
      action: "agent_run.source_closure_recovery_requested"
    )
    expect(event.metadata).to include(
      "agent_run_id" => run.id,
      "project_name" => project.name,
      "branch_name" => "paid/source-closure",
      "result_commit_sha" => "a" * 40,
      "source_closure_commit_sha" => "a" * 40,
      "request_phase" => "requested",
      "request_boundary" => "mcp"
    )
    expect(event.metadata.fetch("queue_job_id")).to be_present
  end

  # @spec PARTIAL-CLOSEOUT-065
  it "reports an audit persistence failure without enqueueing a duplicate job" do
    allow(Audit::RecordEvent).to receive(:call).and_raise(ActiveRecord::RecordInvalid.new(AccountActivityEvent.new))

    result = nil
    expect { result = described_class.call(agent_run: run, actor: user, boundary: "ui") }
      .to have_enqueued_job(SourceClosureRecoveryJob).with(run.id, operator_id: user.id).once

    expect(result).to be_queued_without_audit
    expect(AccountActivityEvent.where(action: "agent_run.source_closure_recovery_requested")).to be_empty
  end

  # @spec PARTIAL-CLOSEOUT-065
  it "does not record an accepted request when enqueueing is refused" do
    allow(SourceClosureRecoveryJob).to receive(:perform_later).with(run.id, operator_id: user.id).and_return(false)

    result = described_class.call(agent_run: run, actor: user, boundary: "ui")

    expect(result).to be_enqueue_failed
    expect(AccountActivityEvent.where(action: "agent_run.source_closure_recovery_requested")).to be_empty
  end
end
