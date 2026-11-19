# frozen_string_literal: true

require "rails_helper"

RSpec.describe CloseoutVerificationJob do
  let(:project) { create(:project) }
  let(:maintainer) { create(:user, :owner, account: project.account) }
  let(:issue) { create(:issue, project:) }
  let(:target_revision) { "fixture-live-revision" }

  around do |example|
    previous = ENV["PAID_DEPLOYED_REVISION"]
    ENV["PAID_DEPLOYED_REVISION"] = target_revision
    example.run
  ensure
    ENV["PAID_DEPLOYED_REVISION"] = previous
  end

  before do
    project.update!(created_by: maintainer)
    FeatureFlags.enable!(:automation_phases, project:)
    project.update!(automation_phase_settings: { "phases" => { "operations" => true } })
    StagedCloseoutAdoption::Enroll.call(project:, actor: maintainer, enabled: true)
    create(:agent_run, :completed, project:, issue:, reconciliation: { "assessment" => {
      "source_revision" => PartialCloseouts::Assessment.source_revision_for(issue),
      "intent_revision" => PartialCloseouts::Assessment.intent_revision_for(issue),
      "criteria" => [ { "criterion" => "Live evidence", "state" => "unmet" } ], "gaps" => []
    } })
    StagedCloseoutAdoption::Mappings.approve(project:, actor: maintainer, issue:, attributes: {
      criterion_key: "Live evidence", stage: "live_environment", phase: "operations", target_shape: "live_signal",
      execution_path: "trusted_measurement", target_key: "agent_planning_hold_reconciliation_closed_count",
      environment_class: Rails.env.to_s, freshness_seconds: 60
    })
  end

  def admitted_run
    CloseoutVerifications::AdmitLiveTarget.call(project:, target_revision:).runs.fetch(0)
  end

  # @spec STAGED-CLOSEOUT-ADOPTION-012
  it "links the allowlisted attempt and records observed evidence without settling another criterion" do
    run = admitted_run
    described_class.perform_now(run.id)

    evidence = run.reload.verification_result.fetch("closeout_verification")
    expect(run).to have_attributes(status: "completed", closeout_measurement_attempt: an_object_having_attributes(status: "succeeded"))
    expect(evidence).to include("outcome" => "observed", "measurement_status" => "succeeded",
      "target_revision" => target_revision)
    expect(evidence.fetch("criterion")).to eq("Live evidence")
  end

  # @spec STAGED-CLOSEOUT-ADOPTION-012
  it "records stale evidence rather than reading after the target changes" do
    run = admitted_run
    ENV["PAID_DEPLOYED_REVISION"] = "newer-live-revision"
    expect(TrustedMeasurements::Checks::PlanningHoldReconciliationClosedCount).not_to receive(:call)

    described_class.perform_now(run.id)

    expect(run.reload.verification_result.dig("closeout_verification", "outcome")).to eq("stale")
  end
end
