# frozen_string_literal: true

require "rails_helper"

# @spec PARTIAL-CLOSEOUT-056
RSpec.describe PartialCloseouts::AcceptanceAuditFailure do
  let(:account) { create(:account) }
  let(:owner) { create(:user, account:) }
  let(:project) { create(:project, account:, created_by: owner) }
  let(:issue) { create(:issue, project:, github_state: "open", paid_state: "completed") }
  let(:run) { create(:agent_run, project:, issue:, goal: "analyze_issue", status: "failed") }

  def failing_run(status:, category: nil, error_message: nil)
    reconciliation = category ? { "acceptance_audit_failure" => { "category" => category } } : {}
    create(:agent_run, project:, issue:, goal: "analyze_issue", status: "failed",
      error_message:, reconciliation:, completed_at: Time.current).tap do |created|
      created.update!(status:)
    end
  end

  it "classifies a completed audit with unmet criteria as a substantive assessment" do
    run.update!(status: "completed", completed_at: Time.current,
      reconciliation: { "assessment" => { "gaps" => [ { "criterion" => "c", "kind" => "agent", "title" => "t" } ] } })

    expect(described_class.classify(run)).to eq(:substantive_assessment)
    expect(described_class).not_to be_transient(run)
  end

  it "classifies cancellation, budget exhaustion, and rate-limit recovery as non-transient" do
    expect(described_class.classify(failing_run(status: "cancelled"))).to eq(:cancelled)
    expect(described_class.classify(failing_run(status: "token_budget_exceeded"))).to eq(:budget_exhausted)
    expect(described_class.classify(failing_run(status: "rate_limited"))).to eq(:rate_limit_recovery_owned)
  end

  it "classifies authentication and configuration failures separately from transport" do
    auth_status = failing_run(status: "auth_expired")
    auth_category = failing_run(status: "failed", category: "authentication_unavailable")

    expect(described_class.classify(auth_status)).to eq(:authentication_or_configuration)
    expect(described_class.classify(auth_category)).to eq(:authentication_or_configuration)
    expect(described_class).not_to be_transient(auth_category)
  end

  it "classifies typed transport categories as transient" do
    %w[transport_error timeout unsuccessful_response invalid_json invalid_assessment].each do |category|
      transient = failing_run(status: "failed", category: category, error_message: "audit failed")

      expect(described_class.classify(transient)).to eq(:transient_transport)
      expect(described_class).to be_transient(transient)
    end
  end

  it "classifies a timeout status as transient" do
    expect(described_class.classify(failing_run(status: "timeout"))).to eq(:transient_transport)
  end

  it "classifies infrastructure interruption signatures without a typed category as transient" do
    activity_timeout = failing_run(status: "failed", error_message: "Activity task timed out")
    exhausted_pool = failing_run(status: "failed", error_message: "no runner: providers exhausted")

    expect(described_class.classify(activity_timeout)).to eq(:transient_transport)
    expect(described_class.classify(exhausted_pool)).to eq(:transient_transport)
  end

  it "classifies legacy transport failure messages as transient" do
    legacy = failing_run(status: "failed", error_message: "Partial closeout assessment transport failed. Retry after runner recovery.")

    expect(described_class.classify(legacy)).to eq(:transient_transport)
  end

  it "classifies a deterministic failure message as non-transient" do
    deterministic = failing_run(status: "failed", error_message: "Partial closeout assessment could not authenticate with the configured runner.")

    expect(described_class.classify(deterministic)).to eq(:non_transient_failure)
    expect(described_class).not_to be_transient(deterministic)
  end

  it "keeps a retried run's original failure signature so the sweep can still classify it" do
    retried_transient = failing_run(status: "failed", category: "transport_error")
    retried_transient.update!(status: "retried")
    retried_deterministic = failing_run(status: "failed",
      error_message: "Partial closeout assessment could not authenticate with the configured runner.")
    retried_deterministic.update!(status: "retried")

    expect(described_class.classify(retried_transient)).to eq(:transient_transport)
    expect(described_class.classify(retried_deterministic)).to eq(:non_transient_failure)
  end

  it "reports non-terminal attempts as not terminal" do
    expect(described_class.classify(failing_run(status: "queued"))).to eq(:not_terminal)
  end
end
