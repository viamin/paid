# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Source-closure recovery" do
  let(:user) { create(:user) }
  let(:project) { create(:project, account: user.account, created_by: user) }
  let(:run) { create(:agent_run, project:, status: "waiting_recovery") }

  # @spec PARTIAL-CLOSEOUT-045
  it "loads the run and queues recovery for an authorized operator" do
    sign_in user

    expect {
      post retry_source_closure_project_agent_run_path(project, run)
    }.to have_enqueued_job(SourceClosureRecoveryJob).with(run.id, operator_id: user.id)

    expect(response).to redirect_to(project_agent_run_path(project, run))
    expect(flash[:notice]).to include("without rerunning coding")
  end

  # @spec PARTIAL-CLOSEOUT-044 PARTIAL-CLOSEOUT-045
  it "shows recovery guidance when job enqueueing is aborted" do
    sign_in user
    allow(SourceClosureRecoveryJob).to receive(:perform_later).with(run.id, operator_id: user.id).and_return(false)

    post retry_source_closure_project_agent_run_path(project, run)

    expect(response).to redirect_to(project_agent_run_path(project, run))
    expect(flash[:alert]).to include("could not be queued")
    expect(run.reload.status).to eq("waiting_recovery")
  end

  # @spec PARTIAL-CLOSEOUT-044 PARTIAL-CLOSEOUT-045
  it "shows waiting diagnostics and the manual recovery action" do
    sign_in user
    run.update!(reconciliation: { "source_closure_recovery" => {
      "failed_step" => "assess_source_closure", "failure_category" => "timeout",
      "next_retry_at" => 10.minutes.from_now.iso8601
    } })

    get project_agent_run_path(project, run)

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Waiting Recovery", "Waiting for recovery: source-closure assessment")
    expect(response.body).to include("Assess source closure", "Timeout", "Retry source-closure assessment")
  end

  # @spec PARTIAL-CLOSEOUT-061
  it "shows the actionable stop reason instead of a completed retry" do
    sign_in user
    run.update!(reconciliation: { "source_closure_recovery" => {
      "failed_step" => "assess_source_closure", "failure_category" => "timeout",
      "stop_reason" => "automatic_recovery_budget_exhausted", "next_retry_at" => nil
    } })

    get project_agent_run_path(project, run)

    expect(response.body).to include("Automatic recovery budget exhausted")
    expect(response.body).not_to include("Next retry</dt><dd>Completed")
  end
end
