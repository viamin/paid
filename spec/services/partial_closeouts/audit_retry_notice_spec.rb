# frozen_string_literal: true

# frozen_string: true

require "rails_helper"

# @spec PARTIAL-CLOSEOUT-056
RSpec.describe PartialCloseouts::AuditRetryNotice do
  let(:account) { create(:account) }
  let(:owner) { create(:user, account:) }
  let(:project) { create(:project, account:, created_by: owner, auto_pick_enabled: true) }
  let(:issue) do
    issue = create(:issue, project:, github_state: "open", paid_state: "completed")
    create(:issue, :pull_request, project:, parent_issue: issue, github_number: 12,
      github_state: "closed", pr_review_phase: "merged")
    issue
  end
  let(:source_revision) { PartialCloseouts::Assessment.source_revision_for(issue) }
  let(:intent_revision) { PartialCloseouts::Assessment.intent_revision_for(issue) }

  def failed_audit(error_message:, category: nil)
    request = create(:issue_continuation_request, issue:, project:, status: "consumed",
      evidence: { "merged_prs" => [], "source_revision" => source_revision, "intent_revision" => intent_revision,
        "continuation_mode" => "acceptance_audit" },
      evidence_digest: source_revision)
    reconciliation = category ? { "acceptance_audit_failure" => { "category" => category } } : {}
    create(:agent_run, :automatic, project:, issue:, goal: "analyze_issue",
      continuation_request: request, status: "failed", error_message:, reconciliation:,
      completed_at: 2.hours.ago)
  end

  it "states retry exhaustion with its reason and the supported operator action" do
    3.times { failed_audit(error_message: "Partial closeout assessment transport failed. Retry after runner recovery.") }

    notice = described_class.call(issue)

    expect(notice.reason).to eq(:retry_exhausted)
    expect(notice.explanation).to include("three automatic audit attempts")
    expect(notice.operator_action).to include("request a fresh acceptance audit")
  end

  it "names the authentication recovery action for a credential failure" do
    failed_audit(error_message: "Partial closeout assessment could not authenticate with the configured runner. Reconnect its credential and retry.")

    notice = described_class.call(issue)

    expect(notice.reason).to eq(:authentication_configuration)
    expect(notice.operator_action).to include("Reconnect the configured runner credential")
  end

  it "names the input-repair action for an invalid-input failure" do
    failed_audit(error_message: "Partial closeout assessment returned invalid JSON.", category: "invalid_json")

    notice = described_class.call(issue)

    expect(notice.reason).to eq(:invalid_input)
    expect(notice.operator_action).to include("runner or audit input")
  end

  it "returns no notice while a bounded retry is still pending or admissible" do
    failed_audit(error_message: "Partial closeout assessment transport failed. Retry after runner recovery.",
      category: "transport_error")

    expect(described_class.call(issue)).to be_nil
  end

  it "returns no notice when no audit attempt exists for the current evidence" do
    expect(described_class.call(issue)).to be_nil
  end
end
