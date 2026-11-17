# frozen_string_literal: true

require "rails_helper"

RSpec.describe MaintenanceReports::Persist do
  let(:project) { create(:project) }
  let(:run) do
    create(:agent_run, :manual, project:, issue: nil, goal: "maintenance", maintenance_objective: "unnecessary_code",
      maintenance_scope: "app/services")
  end
  let(:finding) do
    {
      category: "unused_code", claim: "LegacyWorker has no callers", symbols: [ "LegacyWorker" ],
      locations: [ { "path" => "app/workers/legacy_worker.rb", "line" => 12 } ],
      supporting_evidence: [ { "source" => "debride", "detail" => "no static callers" } ],
      contrary_evidence: [ { "source" => "rails", "detail" => "may be autoloaded" } ],
      raw_tool_confidence: 0.72, agent_assessment: "needs_review", proposed_action: "Verify runtime references",
      validation_plan: "Exercise the production job path", verification_disposition: "unverified"
    }
  end

  # @spec MAINT-020 MAINT-021 MAINT-022 MAINT-025
  it "persists completed coverage and separates tool confidence from agent assessment" do
    report = described_class.call(run:, resolved_scope: "app/workers", completed_checks: [ { "name" => "debride" } ], findings: [ finding ])

    expect(report).to have_attributes(outcome: "completed", resolved_scope: "app/workers")
    occurrence = report.finding_occurrences.sole
    expect(occurrence).to have_attributes(raw_tool_confidence: 0.72, agent_assessment: "needs_review", verification_disposition: "unverified")
    expect(occurrence.maintenance_finding).to have_attributes(project: project, status: "open")
  end

  # @spec MAINT-022
  it "never presents incomplete coverage as a clean or completed scan" do
    report = described_class.call(run:, completed_checks: [ { "name" => "prompt" } ],
      incomplete_checks: [ { "name" => "debride", "reason" => "missing_tool" } ])

    expect(report).to have_attributes(outcome: "partial")
  end

  # @spec MAINT-020 MAINT-022
  it "does not represent the requested scope as the scope actually investigated" do
    report = described_class.call(run:, incomplete_checks: [ { "name" => "investigation", "reason" => "parse_failure" } ])

    expect(report.resolved_scope).to be_nil
  end

  # @spec MAINT-023
  it "preserves a terminal interruption outcome when later evidence is persisted" do
    described_class.call(run:, outcome: "cancelled", evidence: { "phase" => "fallback" })

    report = described_class.call(run:, completed_checks: [ { "name" => "prompt" } ],
      evidence: { "phase" => "agent_report" }, findings: [ finding ])

    expect(report).to have_attributes(outcome: "cancelled", evidence: { "phase" => "agent_report" })
    expect(report.finding_occurrences.sole.claim).to eq(finding[:claim])
  end

  # @spec MAINT-024
  it "preserves a budget-exhausted outcome when a late complete report arrives" do
    described_class.call(run:, outcome: "budget_exhausted")

    report = described_class.call(run:, completed_checks: [ { "name" => "prompt" } ])

    expect(report.outcome).to eq("budget_exhausted")
  end

  # @spec MAINT-022
  it "preserves a partial fallback outcome when a late complete report arrives" do
    described_class.call(run:, incomplete_checks: [ { "name" => "investigation", "reason" => "timeout" } ])

    report = described_class.call(run:, completed_checks: [ { "name" => "prompt" } ])

    expect(report.outcome).to eq("partial")
  end

  # @spec MAINT-020 MAINT-022
  it "retains a completed outcome when a repeated call omits existing findings" do
    described_class.call(run:, findings: [ finding ])

    report = described_class.call(run:, completed_checks: [ { "name" => "prompt" } ])

    expect(report).to have_attributes(outcome: "completed")
    expect(report.finding_occurrences.sole.claim).to eq(finding[:claim])
  end

  # @spec MAINT-026 MAINT-027 MAINT-029
  it "keeps canonical identity through category and line shifts and flags materially changed dismissed evidence" do
    first = described_class.call(run:, findings: [ finding ])
    canonical = first.finding_occurrences.sole.maintenance_finding
    canonical.dismiss!(reason: "Intentional framework hook")
    later_run = create(:agent_run, :manual, project:, issue: nil, goal: "maintenance", maintenance_objective: "unnecessary_code")
    shifted = finding.deep_merge(category: "obsolete_behavior",
      locations: [ { "path" => "app/workers/legacy_worker.rb", "line" => 99 } ],
      supporting_evidence: [ { "source" => "debride", "detail" => "no callers after refactor" } ])

    later = described_class.call(run: later_run, findings: [ shifted ])

    expect(later.finding_occurrences.sole.maintenance_finding).to eq(canonical)
    expect(canonical.reload.category).to eq("obsolete_behavior")
    expect(canonical.reload).to have_attributes(status: "dismissed", reassessment_required: true)
    expect(first.finding_occurrences.sole.locations).to eq(finding[:locations])
  end

  # @spec MAINT-027 MAINT-029
  it "does not reassess a dismissed finding when evidence key order changes" do
    first = described_class.call(run:, findings: [ finding ])
    canonical = first.finding_occurrences.sole.maintenance_finding
    canonical.dismiss!(reason: "Intentional framework hook")
    later_run = create(:agent_run, :manual, project:, issue: nil, goal: "maintenance", maintenance_objective: "unnecessary_code")
    reordered = finding.merge(supporting_evidence: [ { "detail" => "no static callers", "source" => "debride" } ])

    described_class.call(run: later_run, findings: [ reordered ])

    expect(canonical.reload).to have_attributes(status: "dismissed", reassessment_required: false)
  end
end
