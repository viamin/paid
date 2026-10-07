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
  it "escalates a persistent uncovered alert after the documented grace period" do
    create(:dependabot_alert_coverage, project:, account: project.account, alert_number: 41,
      advisory_ghsa_id: "GHSA-test", first_detected_at: 8.days.ago)

    described_class.new(project).call([ alert ])

    expect(Notifications::Publish).to have_received(:call).with(hash_including(blocking: true, severity: :error))
  end

  # @spec DEPENDABOT-COVERAGE-001
  it "retains no patched version as an explicit uncovered state" do
    described_class.new(project).call([ alert.merge(first_patched_version: nil) ])

    expect(project.dependabot_alert_coverages.find_by!(alert_number: 41).coverage_state).to eq("no_patched_version")
  end

  # @spec DEPENDABOT-COVERAGE-001
  it "retains closed, merged, and constraint-blocked remediation states as uncovered" do
    described_class.new(project).call([
      alert.merge(number: 42, remediation_pull_requests: [ { number: 1, state: "closed" } ]),
      alert.merge(number: 43, advisory_ghsa_id: "GHSA-merged", remediation_pull_requests: [ { number: 2, state: "merged" } ]),
      alert.merge(number: 44, advisory_ghsa_id: "GHSA-pinned", coverage_state: "incompatible_constraints", reason: "pinned_vulnerable_resolution")
    ])

    states = project.dependabot_alert_coverages.pluck(:coverage_state)
    expect(states).to include("effective_pr_closed_unmerged", "merged_still_vulnerable", "incompatible_constraints")
  end

  # @spec DEPENDABOT-COVERAGE-001
  it "requires owner, reason, and expiry when accepting an unfixable alert" do
    coverage = create(:dependabot_alert_coverage, project:, account: project.account)

    expect { coverage.accept!(owner: project.account.users.first, reason: "", expires_at: nil) }
      .to raise_error(ActiveRecord::RecordInvalid)
  end
end
