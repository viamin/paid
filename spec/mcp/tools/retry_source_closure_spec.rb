# frozen_string_literal: true

require "rails_helper"

# @spec PARTIAL-CLOSEOUT-045
RSpec.describe Tools::RetrySourceClosure do
  let(:account) { create(:account) }
  let(:user) { create(:user, :member, account:) }
  let(:session) { create(:chat_session, account:, created_by: user) }
  let(:project) { create(:project, account:) }
  let(:run) { create(:agent_run, project:, status: "waiting_recovery", result_commit_sha: "a" * 40) }
  let(:tool) { described_class.new(user:, session:) }

  it "advertises a confirmed write tool through chat and MCP" do
    klass = Tools::Registry.find("retry_source_closure")
    expect(klass).to be_present
    expect(klass.mcp_available?).to be(true)
    expect(klass.write_operation?).to be(true)
    expect(klass.input_schema[:required]).to include("confirmed")
  end

  it "queues only post-processing for the same run" do
    expect { tool.call(agent_run_id: run.id, confirmed: true) }
      .to have_enqueued_job(SourceClosureRecoveryJob).with(run.id, operator_id: user.id)
    expect(run.reload.status).to eq("waiting_recovery")
    expect(project.agent_runs.count).to eq(1)
  end

  it "rejects a request without confirmation" do
    expect { tool.call(agent_run_id: run.id) }.to raise_error(ArgumentError, /Confirmation required/)
    expect(SourceClosureRecoveryJob).not_to have_been_enqueued
  end

  it "rejects completed runs" do
    run.update!(status: "completed")
    expect { tool.call(agent_run_id: run.id, confirmed: true) }.to raise_error(ArgumentError, /not waiting/)
    expect(SourceClosureRecoveryJob).not_to have_been_enqueued
  end

  it "rejects a run outside the user's tenant" do
    foreign_run = create(:agent_run, status: "waiting_recovery")
    expect { tool.call(agent_run_id: foreign_run.id, confirmed: true) }.to raise_error(ActiveRecord::RecordNotFound)
    expect(SourceClosureRecoveryJob).not_to have_been_enqueued
  end

  it "enforces the run policy before enqueueing" do
    viewer = create(:user, :viewer, account:)
    tool = described_class.new(user: viewer, session:)
    expect { tool.call(agent_run_id: run.id, confirmed: true) }.to raise_error(Pundit::NotAuthorizedError)
    expect(SourceClosureRecoveryJob).not_to have_been_enqueued
  end

  it "reports enqueue refusal" do
    job = instance_double(SourceClosureRecoveryJob, successfully_enqueued?: false)
    allow(SourceClosureRecoveryJob).to receive(:perform_later).with(run.id, operator_id: user.id).and_return(job)
    expect { tool.call(agent_run_id: run.id, confirmed: true) }.to raise_error(ArgumentError, /could not be queued/)
  end

  it "reports an aborted enqueue" do
    allow(SourceClosureRecoveryJob).to receive(:perform_later).with(run.id, operator_id: user.id).and_return(false)
    expect { tool.call(agent_run_id: run.id, confirmed: true) }.to raise_error(ArgumentError, /could not be queued/)
  end

  it "exposes bounded recovery diagnostics without arbitrary reconciliation data" do
    run.update!(reconciliation: { "source_closure_recovery" => {
      "failed_step" => "assess_source_closure", "commit_sha" => "a" * 40,
      "failure_category" => "timeout", "attempts" => 3, "private_payload" => "sensitive"
    }, "assessment" => { "raw_output" => "sensitive" } })
    result = Tools::GetAgentRun.new(user:, session:).call(agent_run_id: run.id)
    expect(result.fetch(:source_closure_recovery)).to eq(
      "failed_step" => "assess_source_closure", "commit_sha" => "a" * 40,
      "failure_category" => "timeout", "attempts" => 3
    )
    expect(result).not_to have_key(:reconciliation)
  end
end
