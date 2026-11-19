# frozen_string_literal: true

require "rails_helper"

RSpec.describe MaintenanceReports::Persist do
  let(:project) { create(:project) }
  let(:run) { create(:agent_run, :manual, :running, project:, issue: nil, goal: "maintenance", maintenance_guidance: "Inspect callbacks") }
  let(:finding) do
    { category: "unused_code", claim: "Legacy callback has no callers", symbols: [ "Legacy#call" ],
      locations: [ { path: "app/legacy.rb", line: 12 } ], supporting_evidence: [ "Inspected callers" ],
      contrary_evidence: [ "May be invoked dynamically" ], evidence_source: "agent", analyzer_provenance: {},
      verification_disposition: "unverified" }
  end
  let(:payload) do
    { resolved_scope: "app/legacy.rb", exclusions: [ "vendor" ], completed_checks: [ { name: "callers" } ],
      incomplete_checks: [], evidence: { inspected_revision: "a" * 40 }, findings: [ finding ] }
  end

  # @spec MAINT-023 MAINT-024 MAINT-025
  it "preserves structured findings and scope when cancellation precedes completion" do
    run.log!("stdout", "<!-- maintenance-report-start -->\n#{JSON.generate(payload)}\n<!-- maintenance-report-end -->")
    run.cancel!

    report = run.reload.maintenance_report
    expect(report).to have_attributes(outcome: "cancelled", resolved_scope: "app/legacy.rb")
    expect(report.evidence).to include("inspected_revision" => "a" * 40)
    expect(report.finding_occurrences.sole.claim).to eq(finding[:claim])
  end

  # @spec MAINT-020 MAINT-021 MAINT-025
  it "does not erase report evidence when persistence is replayed without evidence" do
    report = described_class.call(run:, **payload)
    described_class.call(run:)

    expect(report.reload).to have_attributes(resolved_scope: "app/legacy.rb", exclusions: [ "vendor" ])
    expect(report.evidence).to include("inspected_revision" => "a" * 40)
    expect(report.completed_checks).to eq([ { "name" => "callers" } ])
  end

  # @spec MAINT-022
  it "rejects a report with no completed or incomplete checks rather than claiming clean coverage" do
    output = "<!-- maintenance-report-start -->\n#{JSON.generate(payload.merge(completed_checks: [], findings: []))}\n<!-- maintenance-report-end -->"
    expect { MaintenanceReports::AgentReport.parse(output) }.to raise_error(MaintenanceReports::AgentReport::InvalidReport)
  end

  # @spec MAINT-025 POSTGRESQL-PERSISTENCE-006
  it "rejects an occurrence attached to a different project in the same account" do
    report = described_class.call(run:, **payload)
    other_project = create(:project, account: project.account)
    other = MaintenanceFinding.create!(project: other_project, account: project.account, recipe_key: "custom",
      identity_digest: "b" * 64, category: "unused_code", claim: "Other project finding")

    expect { report.finding_occurrences.sole.update!(maintenance_finding: other) }.to raise_error(ActiveRecord::RecordInvalid)
  end

  # @spec POSTGRESQL-PERSISTENCE-006 MAINT-025
  it "rejects direct database links to a run in another project" do
    report = described_class.call(run:, **payload)
    other_run = create(:agent_run, :manual, project: create(:project, account: project.account), issue: nil, goal: "maintenance", maintenance_guidance: "Inspect")
    TenantContext.with(project.account) do
      expect do
        MaintenanceReport.transaction(requires_new: true) { report.update_columns(agent_run_id: other_run.id) }
      end.to raise_error(ActiveRecord::InvalidForeignKey, /must belong/)
    end
  end

  # @spec POSTGRESQL-PERSISTENCE-006 MAINT-025
  it "rejects direct database links to a finding in another project" do
    report = described_class.call(run:, **payload)
    other = MaintenanceFinding.create!(project: create(:project, account: project.account), account: project.account,
      recipe_key: "custom", identity_digest: "c" * 64, category: "unused_code", claim: "Other")
    TenantContext.with(project.account) do
      expect do
        MaintenanceFindingOccurrence.transaction(requires_new: true) do
          report.finding_occurrences.sole.update_columns(maintenance_finding_id: other.id)
        end
      end.to raise_error(ActiveRecord::InvalidForeignKey, /must belong/)
    end
  end

  # @spec MAINT-024
  it "retains collected evidence when the run exhausts its token budget" do
    run.log!("stdout", "<!-- maintenance-report-start -->\n#{JSON.generate(payload)}\n<!-- maintenance-report-end -->")
    run.update!(status: "token_budget_exceeded", completed_at: Time.current)

    expect(run.reload.maintenance_report).to have_attributes(outcome: "budget_exhausted", resolved_scope: "app/legacy.rb")
    expect(run.maintenance_report.finding_occurrences.sole.supporting_evidence).to eq([ "Inspected callers" ])
  end

  # @spec MAINT-023
  it "changes an already persisted success report to cancelled while retaining its findings" do
    described_class.call(run:, **payload)
    run.cancel!

    expect(run.reload.maintenance_report).to have_attributes(outcome: "cancelled", resolved_scope: "app/legacy.rb")
    expect(run.maintenance_report.finding_occurrences.count).to eq(1)
  end
end
