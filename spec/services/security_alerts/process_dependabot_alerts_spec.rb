# frozen_string_literal: true

require "rails_helper"

RSpec.describe SecurityAlerts::ProcessDependabotAlerts do
  let(:project) { create(:project) }
  let(:alert) do
    {
      number: 41, state: "open", dependency_name: "brace-expansion", dependency_ecosystem: "npm",
      manifest_path: "package-lock.json", advisory_ghsa_id: "GHSA-test", remediation_pull_requests: [],
      first_patched_version: "5.0.6", evidence: { html_url: "https://example.test/alert/41" }
    }
  end

  before { allow(Notifications::Publish).to receive(:call) }

  # @spec DEPENDABOT-COVERAGE-001
  it "keeps an alert without a remediation PR visible with an unknown reason" do
    described_class.new(project).call([ alert ])

    coverage = project.dependabot_alert_coverages.find_by!(alert_number: 41)
    expect(coverage).to have_attributes(coverage_state: "awaiting_processing", reason: "unknown")
  end

  # @spec DEPENDABOT-COVERAGE-001
  it "records an authoritative open remediation PR without treating it as fixed" do
    described_class.new(project).call([ alert.merge(remediation_pull_requests: [ { number: 42, state: "open" } ]) ])

    coverage = project.dependabot_alert_coverages.find_by!(alert_number: 41)
    expect(coverage).to have_attributes(coverage_state: "effective_pr_open", reason: "open_remediation_pr")
  end

  # @spec DEPENDABOT-COVERAGE-001
  it "preserves an unexpired operator acceptance during a normal poll" do
    coverage = create(:dependabot_alert_coverage, project:, account: project.account, alert_number: 41,
      dependency_name: alert[:dependency_name], dependency_ecosystem: alert[:dependency_ecosystem],
      manifest_path: alert[:manifest_path], advisory_ghsa_id: alert[:advisory_ghsa_id],
      first_detected_at: 8.days.ago)
    coverage.accept!(owner: project.account.users.first, reason: "Risk accepted", expires_at: 1.day.from_now)

    described_class.new(project).call([ alert ])

    expect(coverage.reload).to have_attributes(coverage_state: "accepted", reason: "operator_accepted")
    expect(Notifications::Publish).not_to have_received(:call)
  end

  # @spec DEPENDABOT-COVERAGE-001
  it "escalates a persistent uncovered alert after the documented grace period" do
    create(:dependabot_alert_coverage, project:, account: project.account, alert_number: 41,
      advisory_ghsa_id: "GHSA-test", first_detected_at: 8.days.ago)

    described_class.new(project).call([ alert ])

    expect(Notifications::Publish).to have_received(:call).with(hash_including(blocking: true, severity: :error))
  end

  # @spec DEPENDABOT-COVERAGE-001
  it "does not escalate an alert whose open PR closed unmerged after the alert was first detected" do
    create(:dependabot_alert_coverage, project:, account: project.account, alert_number: 41,
      advisory_ghsa_id: "GHSA-test", coverage_state: "effective_pr_open",
      first_detected_at: 30.days.ago, uncovered_since: nil)

    described_class.new(project).call([ alert.merge(remediation_pull_requests: [ { number: 42, state: "closed" } ]) ])

    coverage = project.dependabot_alert_coverages.find_by!(alert_number: 41)
    expect(coverage.coverage_state).to eq("effective_pr_closed_unmerged")
    expect(coverage.uncovered_since).to be_present
    expect(coverage.uncovered_since).to be > 1.minute.ago
    expect(coverage.escalated_at).to be_nil
    expect(Notifications::Publish).not_to have_received(:call)
  end

  # @spec DEPENDABOT-COVERAGE-001
  it "resets uncovered_since when a remediation PR reopens and escalates only after a fresh grace period" do
    create(:dependabot_alert_coverage, project:, account: project.account, alert_number: 41,
      advisory_ghsa_id: "GHSA-test", coverage_state: "effective_pr_closed_unmerged",
      first_detected_at: 30.days.ago, uncovered_since: 30.days.ago)

    described_class.new(project).call([ alert.merge(remediation_pull_requests: [ { number: 42, state: "open" } ]) ])

    coverage = project.dependabot_alert_coverages.find_by!(alert_number: 41)
    expect(coverage.coverage_state).to eq("effective_pr_open")
    expect(coverage.uncovered_since).to be_nil
    expect(coverage.escalated_at).to be_nil
    expect(Notifications::Publish).not_to have_received(:call)
  end

  # @spec DEPENDABOT-COVERAGE-001
  it "re-arms escalation after an effective remediation PR later closes unmerged" do
    coverage = create(:dependabot_alert_coverage, project:, account: project.account, alert_number: 41,
      advisory_ghsa_id: "GHSA-test", coverage_state: "effective_pr_closed_unmerged",
      first_detected_at: 30.days.ago, uncovered_since: 30.days.ago, escalated_at: 1.day.ago)

    described_class.new(project).call([ alert.merge(remediation_pull_requests: [ { number: 42, state: "open" } ]) ])

    expect(coverage.reload).to have_attributes(uncovered_since: nil, escalated_at: nil)

    described_class.new(project).call([ alert.merge(remediation_pull_requests: [ { number: 42, state: "closed" } ]) ])

    travel 8.days do
      described_class.new(project).call([ alert.merge(remediation_pull_requests: [ { number: 42, state: "closed" } ]) ])
    end

    expect(Notifications::Publish).to have_received(:call).with(hash_including(blocking: true, severity: :error))
  end

  # @spec DEPENDABOT-COVERAGE-001
  it "retains no patched version as an explicit uncovered state" do
    described_class.new(project).call([ alert.merge(first_patched_version: nil) ])

    expect(project.dependabot_alert_coverages.find_by!(alert_number: 41).coverage_state).to eq("no_patched_version")
  end

  # @spec DEPENDABOT-COVERAGE-001
  it "retains closed and merged remediation states as uncovered" do
    described_class.new(project).call([
      alert.merge(number: 42, remediation_pull_requests: [ { number: 1, state: "closed" } ]),
      alert.merge(number: 43, advisory_ghsa_id: "GHSA-merged", remediation_pull_requests: [ { number: 2, state: "merged" } ])
    ])

    states = project.dependabot_alert_coverages.pluck(:coverage_state)
    expect(states).to include("effective_pr_closed_unmerged", "merged_still_vulnerable")
  end

  # @spec DEPENDABOT-COVERAGE-001
  it "resolves the escalation notification when an open remediation PR restores coverage" do
    coverage = create(:dependabot_alert_coverage, project:, account: project.account, alert_number: 41,
      advisory_ghsa_id: "GHSA-test", coverage_state: "effective_pr_closed_unmerged",
      first_detected_at: 30.days.ago, uncovered_since: 30.days.ago, escalated_at: 1.day.ago)
    notification = create(:notification, :error, account: project.account, blocking: true,
      source: "dependabot_alert_coverage", subject: coverage,
      metadata: { project_id: project.id, alert_number: 41, reason: "closed_unmerged" })

    described_class.new(project).call([ alert.merge(remediation_pull_requests: [ { number: 42, state: "open" } ]) ])

    expect(coverage.reload).to have_attributes(coverage_state: "effective_pr_open", escalated_at: nil)
    expect(notification.reload.resolved_at).to be_present
  end

  # @spec DEPENDABOT-COVERAGE-001
  it "resolves the escalation notification when the operator accepts the alert" do
    coverage = create(:dependabot_alert_coverage, project:, account: project.account, alert_number: 41,
      advisory_ghsa_id: "GHSA-test", coverage_state: "awaiting_processing",
      first_detected_at: 30.days.ago, uncovered_since: 30.days.ago, escalated_at: 1.day.ago)
    notification = create(:notification, :error, account: project.account, blocking: true,
      source: "dependabot_alert_coverage", subject: coverage,
      metadata: { project_id: project.id, alert_number: 41, reason: "unknown" })
    coverage.accept!(owner: project.account.users.first, reason: "Risk accepted", expires_at: 1.day.from_now)

    described_class.new(project).call([ alert ])

    expect(notification.reload.resolved_at).to be_present
  end

  # @spec DEPENDABOT-COVERAGE-001
  it "resolves the escalation notification when the alert disappears from GitHub" do
    coverage = create(:dependabot_alert_coverage, project:, account: project.account, alert_number: 42,
      alert_state: "open", escalated_at: 1.day.ago)
    notification = create(:notification, :error, account: project.account, blocking: true,
      source: "dependabot_alert_coverage", subject: coverage,
      metadata: { project_id: project.id, alert_number: 42, reason: "unknown" })

    described_class.new(project).call([ alert ])

    expect(coverage.reload.alert_state).to eq("resolved")
    expect(notification.reload.resolved_at).to be_present
  end

  # @spec DEPENDABOT-COVERAGE-001
  it "keeps the escalation notification active while the alert stays uncovered" do
    coverage = create(:dependabot_alert_coverage, project:, account: project.account, alert_number: 41,
      advisory_ghsa_id: "GHSA-test", coverage_state: "awaiting_processing",
      first_detected_at: 30.days.ago, uncovered_since: 30.days.ago, escalated_at: 1.day.ago)
    notification = create(:notification, :error, account: project.account, blocking: true,
      source: "dependabot_alert_coverage", subject: coverage,
      metadata: { project_id: project.id, alert_number: 41, reason: "unknown" })

    described_class.new(project).call([ alert ])

    expect(coverage.reload.escalated_at).to be_present
    expect(notification.reload.resolved_at).to be_nil
  end

  # @spec DEPENDABOT-COVERAGE-001
  it "resolves open coverage records absent from the authoritative alert snapshot" do
    open_coverage = create(:dependabot_alert_coverage, project:, account: project.account, alert_number: 42,
      alert_state: "open")
    resolved_coverage = create(:dependabot_alert_coverage, project:, account: project.account, alert_number: 43,
      advisory_ghsa_id: "GHSA-already-resolved", alert_state: "resolved")

    described_class.new(project).call([ alert ])

    expect(open_coverage.reload.alert_state).to eq("resolved")
    expect(resolved_coverage.reload.alert_state).to eq("resolved")
  end

  # @spec DEPENDABOT-COVERAGE-001
  it "lands constraint-blocked alerts in awaiting_processing when GitHub provides no incompatibility evidence" do
    described_class.new(project).call([
      alert.merge(number: 44, advisory_ghsa_id: "GHSA-pinned", first_patched_version: nil)
    ])

    coverage = project.dependabot_alert_coverages.find_by!(alert_number: 44)
    expect(coverage.coverage_state).to eq("no_patched_version")
  end

  # @spec DEPENDABOT-COVERAGE-001
  it "requires owner, reason, and expiry when accepting an unfixable alert" do
    coverage = create(:dependabot_alert_coverage, project:, account: project.account)

    expect { coverage.accept!(owner: project.account.users.first, reason: "", expires_at: nil) }
      .to raise_error(ActiveRecord::RecordInvalid)
  end
end
