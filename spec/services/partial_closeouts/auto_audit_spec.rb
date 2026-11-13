# frozen_string_literal: true

require "rails_helper"

RSpec.describe PartialCloseouts::AutoAudit do
  let(:account) { create(:account) }
  let(:owner) { create(:user, account:) }
  let(:project) { create(:project, account:, created_by: owner, auto_pick_enabled: true) }
  let(:issue) { create(:issue, project:, github_state: "open", paid_state: "completed") }

  before do
    create(:issue, :pull_request, project:, parent_issue: issue, github_number: 12,
      github_state: "closed", pr_review_phase: "merged")
  end

  # @spec PARTIAL-CLOSEOUT-051
  it "schedules one report-only audit despite its own stale prerequisite notification" do
    create(:notification, :error, account:, subject: issue,
      source: PartialCloseouts::PREREQUISITE_NOTIFICATION_SOURCE, blocking: true)

    result = described_class.call(issue:)

    expect(result).to be_scheduled
    expect(result.agent_run.goal).to eq("analyze_issue")
    expect(Automation::Strategies::AutoPick::DefaultCandidateSource.eligible_scope(project).where(id: issue.id)).to be_empty
  end

  # @spec PARTIAL-CLOSEOUT-037
  it "queues one automatic report-only audit after merge and never repeats it for the same evidence" do
    first = described_class.call(issue:)

    expect(first.scheduled?).to be(true)
    expect(first.agent_run.goal).to eq("analyze_issue")
    expect(first.agent_run.auto_pick).to be(true)
    expect(first.agent_run.continuation_request.evidence["continuation_mode"]).to eq("acceptance_audit")

    first.agent_run.update!(status: "completed", completed_at: Time.current)
    second = described_class.call(issue:)

    expect(second.code).to eq(:already_audited)
    expect(issue.agent_runs.count).to eq(1)
  end

  # @spec PARTIAL-CLOSEOUT-037
  it "does not replace an operator's audit for the same evidence generation" do
    manual = Issues::RequestAcceptanceAudit.call(issue:, actor: owner)
    manual.agent_run.update!(status: "completed", completed_at: Time.current)

    result = described_class.call(issue:)

    expect(result.code).to eq(:already_audited)
    expect(issue.agent_runs.count).to eq(1)
  end

  # @spec PARTIAL-CLOSEOUT-048
  it "audits again when approved issue intent changes without new source evidence" do
    first = described_class.call(issue:)
    first.agent_run.update!(status: "completed", completed_at: Time.current)
    issue.update!(body: "Updated acceptance criteria")

    second = described_class.call(issue:)

    expect(second).to be_scheduled
    expect(second.agent_run.continuation_request.evidence["intent_revision"])
      .to eq(PartialCloseouts::Assessment.intent_revision_for(issue))
  end

  # @spec PARTIAL-CLOSEOUT-048
  it "uses a legacy audit's recorded intent when deciding whether to repeat it" do
    first = described_class.call(issue:)
    request = first.agent_run.continuation_request
    old_intent = request.evidence.fetch("intent_revision")
    request.update!(evidence: request.evidence.except("intent_revision"))
    first.agent_run.update!(status: "completed", completed_at: Time.current,
      reconciliation: { "assessment" => { "source_revision" => request.evidence.fetch("source_revision"),
        "intent_revision" => old_intent, "gaps" => [] } })

    expect(described_class.call(issue:).code).to eq(:assessment_current)

    issue.update!(body: "Changed acceptance criteria")
    expect(described_class.call(issue:)).to be_scheduled
  end

  # @spec PARTIAL-CLOSEOUT-037
  it "retries a transiently failed audit for the same evidence after backoff" do
    first = described_class.call(issue:)
    first.agent_run.update!(status: "failed", error_message: "Partial closeout assessment transport failed. Retry after runner recovery.", completed_at: 2.hours.ago)

    result = described_class.call(issue:)

    expect(result).to be_scheduled
    expect(issue.agent_runs.count).to eq(2)
  end

  # @spec PARTIAL-CLOSEOUT-048
  it "waits before retrying a transient failure" do
    first = described_class.call(issue:)
    first.agent_run.update!(status: "failed", error_message: "Partial closeout assessment timed out. Retry after runner recovery.", completed_at: Time.current)

    expect(described_class.call(issue:).code).to eq(:retry_backoff)
    expect(issue.agent_runs.count).to eq(1)
  end

  # @spec PARTIAL-CLOSEOUT-048
  it "retries a timed-out audit run after backoff" do
    first = described_class.call(issue:)
    first.agent_run.update!(status: "timeout", completed_at: 2.hours.ago)

    expect(described_class.call(issue:)).to be_scheduled
    expect(issue.agent_runs.count).to eq(2)
  end

  # @spec PARTIAL-CLOSEOUT-048
  it "uses the typed failure category for new audit attempts" do
    first = described_class.call(issue:)
    first.agent_run.update!(status: "failed", error_message: "Audit failed",
      reconciliation: { "acceptance_audit_failure" => { "category" => "transport_error" } }, completed_at: 2.hours.ago)

    expect(described_class.call(issue:)).to be_scheduled
  end

  # @spec PARTIAL-CLOSEOUT-048
  it "retries a bounded invalid JSON audit after the transport is repaired" do
    first = described_class.call(issue:)
    first.agent_run.update!(status: "failed", error_message: "Partial closeout assessment returned invalid JSON.",
      reconciliation: { "acceptance_audit_failure" => { "category" => "invalid_json" } }, completed_at: 2.hours.ago)

    second = described_class.call(issue:)
    expect(second).to be_scheduled
    second.agent_run.update!(status: "failed", error_message: "Partial closeout assessment returned invalid JSON.",
      reconciliation: { "acceptance_audit_failure" => { "category" => "invalid_json" } }, completed_at: 2.hours.ago)

    third = described_class.call(issue:)
    expect(third).to be_scheduled
    third.agent_run.update!(status: "failed", error_message: "Partial closeout assessment returned invalid JSON.",
      reconciliation: { "acceptance_audit_failure" => { "category" => "invalid_json" } }, completed_at: 2.hours.ago)

    expect(described_class.call(issue:).code).to eq(:retry_exhausted)
    expect(issue.agent_runs.count).to eq(3)
  end

  # @spec PARTIAL-CLOSEOUT-048
  it "stops automatic retries after a bounded number of transient failures" do
    3.times do
      result = Issues::RequestAcceptanceAudit.call(issue:, actor: owner)
      result.agent_run.update!(status: "failed", error_message: "Partial closeout assessment transport failed. Retry after runner recovery.", completed_at: 2.hours.ago)
    end

    expect(described_class.call(issue:).code).to eq(:retry_exhausted)
    expect(issue.agent_runs.count).to eq(3)
  end

  # @spec PARTIAL-CLOSEOUT-048
  it "bounds the retry budget per source revision when the approved intent keeps changing" do
    2.times do |index|
      result = described_class.call(issue:)
      result.agent_run.update!(status: "failed",
        error_message: "Partial closeout assessment transport failed. Retry after runner recovery.",
        completed_at: 2.hours.ago)
      issue.update!(body: "Changed acceptance criteria #{index}")
    end

    third = described_class.call(issue:)
    expect(third).to be_scheduled
    third.agent_run.update!(status: "failed",
      error_message: "Partial closeout assessment transport failed. Retry after runner recovery.",
      completed_at: 2.hours.ago)
    issue.update!(body: "Changed acceptance criteria again")

    expect(described_class.call(issue:).code).to eq(:retry_exhausted)
    expect(issue.agent_runs.count).to eq(3)
  end

  # @spec PARTIAL-CLOSEOUT-048
  it "retries an audit that failed on a Temporal activity timeout" do
    first = described_class.call(issue:)
    first.agent_run.update!(status: "failed", error_message: "Activity task timed out", completed_at: 2.hours.ago)

    expect(described_class.call(issue:)).to be_scheduled
    expect(issue.agent_runs.count).to eq(2)
  end

  # @spec PARTIAL-CLOSEOUT-048
  it "retries an audit that never reached a runner" do
    first = described_class.call(issue:)
    first.agent_run.update!(status: "failed", error_message: "providers exhausted", completed_at: 2.hours.ago)

    expect(described_class.call(issue:)).to be_scheduled
    expect(issue.agent_runs.count).to eq(2)
  end

  # @spec PARTIAL-CLOSEOUT-048
  it "does not automatically repeat a non-transient failure" do
    first = described_class.call(issue:)
    first.agent_run.update!(status: "failed", error_message: "Partial closeout assessment could not authenticate with the configured runner.", completed_at: 2.hours.ago)

    expect(described_class.call(issue:).code).to eq(:already_audited)
    expect(issue.agent_runs.count).to eq(1)
  end

  # @spec PARTIAL-CLOSEOUT-037
  it "allows one new audit after a new merged PR changes the evidence generation" do
    first = described_class.call(issue:)
    first.agent_run.update!(status: "completed", completed_at: Time.current)
    create(:issue, :pull_request, project:, parent_issue: issue, github_number: 13,
      github_state: "closed", pr_review_phase: "merged")

    second = described_class.call(issue:)

    expect(second.scheduled?).to be(true)
    expect(second.agent_run.id).not_to eq(first.agent_run.id)
    expect(second.agent_run.continuation_request.evidence_digest)
      .not_to eq(first.agent_run.continuation_request.evidence_digest)
    expect(second.agent_run.continuation_request.evidence["source_revision"])
      .not_to eq(first.agent_run.continuation_request.evidence["source_revision"])
  end

  # @spec PARTIAL-CLOSEOUT-042
  it "allows one new audit when completed performance evidence changes the source revision" do
    first = described_class.call(issue:)
    first.agent_run.update!(status: "completed", completed_at: Time.current)
    first.agent_run.update!(reconciliation: {
      "technical_prerequisite_evidence" => { "recorded_at" => Time.current.iso8601, "status" => "completed" }
    })

    second = described_class.call(issue:)

    expect(second).to be_scheduled
    expect(second.agent_run.continuation_request.evidence_digest)
      .to eq(first.agent_run.continuation_request.evidence_digest)
    expect(second.agent_run.continuation_request.evidence["source_revision"])
      .not_to eq(first.agent_run.continuation_request.evidence["source_revision"])
  end

  # @spec TRUSTED-MEASUREMENTS-006
  it "allows one new audit when trusted measurement evidence changes without another merged PR" do
    first = described_class.call(issue:)
    first.agent_run.update!(status: "completed", completed_at: Time.current)
    create(:trusted_measurement_attempt, :succeeded, project:, issue:)

    second = described_class.call(issue:)

    expect(second.scheduled?).to be(true)
    expect(second.agent_run.id).not_to eq(first.agent_run.id)
    expect(second.agent_run.continuation_request.evidence_digest)
      .to eq(PartialCloseouts::Assessment.source_revision_for(issue))
  end

  # @spec TRUSTED-MEASUREMENTS-006
  it "does not repeat an audit when only the measurement execution timestamp changes" do
    attempt = create(:trusted_measurement_attempt, :succeeded, project:, issue:)
    first = described_class.call(issue:)
    first.agent_run.update!(status: "completed", completed_at: Time.current)

    attempt.update!(executed_at: 1.hour.from_now)
    second = described_class.call(issue:)

    expect(second.code).to eq(:already_audited)
    expect(issue.agent_runs.count).to eq(1)
  end

  # @spec PARTIAL-CLOSEOUT-037
  it "keeps a dependency-held closeout for an operator" do
    dependency = create(:issue, project:, github_state: "open", paid_state: "new")
    create(:issue_dependency, issue:, depends_on_issue: dependency)

    result = described_class.call(issue:)

    expect(result.code).to eq(:blocked)
    expect(issue.agent_runs).to be_empty
  end

  # @spec PARTIAL-CLOSEOUT-037
  it "does not bypass disabled auto-pick" do
    project.update!(auto_pick_enabled: false)

    result = described_class.call(issue:)

    expect(result.code).to eq(:automation_disabled)
    expect(issue.agent_runs).to be_empty
  end
end
