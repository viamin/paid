# frozen_string_literal: true

require "rails_helper"

# @spec PARTIAL-CLOSEOUT-056
RSpec.describe PartialCloseouts::AuditFailureClassification do
  let(:account) { create(:account) }
  let(:owner) { create(:user, account:) }
  let(:project) { create(:project, account:, created_by: owner, auto_pick_enabled: true) }
  let(:issue) { create(:issue, project:, github_state: "open", paid_state: "completed") }
  let(:run) do
    request = create(:issue_continuation_request, issue:, project:, status: "consumed",
      evidence: { "merged_prs" => [], "source_revision" => "rev-1", "continuation_mode" => "acceptance_audit",
                  "intent_revision" => "intent-1" },
      evidence_digest: "rev-1")
    create(:agent_run, :automatic, project:, issue:, goal: "analyze_issue",
      continuation_request: request, status: "failed")
  end

  def classified(status: "failed", error_message: nil, reconciliation: {})
    run.update!(status:, error_message:, reconciliation:)
    described_class.category(run.reload)
  end

  it "classifies transport unavailability as transient infrastructure" do
    expect(classified(status: "timeout")).to eq(:transient_infrastructure)
    expect(classified(error_message: "Partial closeout assessment transport failed. Retry after runner recovery."))
      .to eq(:transient_infrastructure)
    expect(classified(reconciliation: { "acceptance_audit_failure" => { "category" => "transport_error" } }))
      .to eq(:transient_infrastructure)
    expect(classified(reconciliation: { "acceptance_audit_failure" => { "category" => "unsuccessful_response" } }))
      .to eq(:transient_infrastructure)
  end

  it "classifies infrastructure interruptions without a typed category as transient" do
    expect(classified(error_message: "Activity task timed out")).to eq(:transient_infrastructure)
    expect(classified(error_message: "All providers exhausted")).to eq(:transient_infrastructure)
    expect(classified(error_message: "partial closeout assessment failed: transport returned an unsuccessful response."))
      .to eq(:transient_infrastructure)
  end

  it "classifies invalid or unusable model output as invalid input, never transient" do
    expect(classified(reconciliation: { "acceptance_audit_failure" => { "category" => "invalid_json" } }))
      .to eq(:invalid_input)
    expect(classified(reconciliation: { "acceptance_audit_failure" => { "category" => "invalid_assessment" } }))
      .to eq(:invalid_input)
  end

  it "classifies authentication and configuration failures separately from transient transport" do
    expect(classified(reconciliation: { "acceptance_audit_failure" => { "category" => "authentication_unavailable" } }))
      .to eq(:authentication_configuration)
    expect(classified(error_message: "Partial closeout assessment could not authenticate with the configured runner. Reconnect its credential and retry."))
      .to eq(:authentication_configuration)
    expect(classified(status: "auth_expired")).to eq(:authentication_configuration)
  end

  it "classifies cancellation, budget exhaustion, and rate-limit in-place recovery as their own categories" do
    expect(classified(status: "cancelled")).to eq(:cancellation)
    expect(classified(status: "token_budget_exceeded")).to eq(:budget_exhausted)
    expect(classified(status: "rate_limited")).to eq(:rate_limit_recovery)
  end

  it "classifies a completed attempt as a substantive assessment even when criteria were unmet" do
    expect(classified(status: "completed")).to eq(:substantive_assessment)
  end

  it "fails closed to non-transient for an unrecognized failure" do
    expect(classified(error_message: "Something unexpected happened")).to eq(:non_transient_failure)
  end

  it "classifies a superseded attempt and an in-flight attempt as not retryable through this policy" do
    expect(classified(status: "retried")).to eq(:already_retried)
    expect(classified(status: "queued")).to eq(:attempt_in_flight)
  end
end
