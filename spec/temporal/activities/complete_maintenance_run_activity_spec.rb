# frozen_string_literal: true

require "rails_helper"

RSpec.describe Activities::CompleteMaintenanceRunActivity do
  let(:project) { create(:project) }
  let(:run) do
    create(:agent_run, goal: "maintenance", status: "running", issue: nil,
      custom_prompt: "Audit workflow A", maintenance_guidance: "Audit workflow A",
      maintenance_scope_kind: "named", maintenance_scope: "app/workflows/a.rb")
  end

  def report_output(**overrides)
    payload = {
      resolved_scope: "app/workflows/a.rb", exclusions: [],
      completed_checks: [ { name: "prompt investigation" } ], incomplete_checks: [], evidence: {}, findings: []
    }.merge(overrides)
    "<!-- maintenance-report-start -->\n#{JSON.generate(payload)}\n<!-- maintenance-report-end -->"
  end

  # @spec MAINT-020
  it "completes a report-only run successfully with no findings" do
    run.log!("stdout", report_output)

    result = described_class.new.execute(agent_run_id: run.id)

    expect(result).to include(agent_run_id: run.id, success: true)
    expect(run.reload.status).to eq("completed")
    expect(run.pull_request_url).to be_nil
    expect(run.maintenance_report).to have_attributes(outcome: "clean")
  end

  # @spec MAINT-020 MAINT-021
  it "persists a report emitted after more than 500 stdout log entries" do
    500.times { |index| run.log!("stdout", "Investigation progress #{index}") }
    run.log!("stdout", report_output)

    described_class.new.execute(agent_run_id: run.id)

    expect(run.reload.maintenance_report).to have_attributes(
      outcome: "clean",
      completed_checks: [ { "name" => "prompt investigation" } ]
    )
  end

  # @spec MAINT-043
  it "retains pre-agent tool provenance as completed report evidence" do
    run.update!(external_metadata: {
      "maintenance_tool_evidence" => {
        "completed_checks" => [ { "name" => "knip", "provenance" => { "version" => "5.0" } } ],
        "incomplete_checks" => []
      }
    })
    run.log!("stdout", report_output)

    described_class.new.execute(agent_run_id: run.id)

    expect(run.reload.maintenance_report.completed_checks).to include(
      "name" => "knip", "provenance" => { "version" => "5.0" }
    )
  end

  # @spec MAINT-022
  it "forces a partial report when a planned analyzer dependency could not be installed" do
    run.update!(external_metadata: {
      "maintenance_tool_evidence" => {
        "completed_checks" => [],
        "incomplete_checks" => [ { "name" => "exhale_provision", "reason" => "dependency_install_failed" } ]
      }
    })
    run.log!("stdout", report_output)

    described_class.new.execute(agent_run_id: run.id)

    expect(run.reload.maintenance_report).to have_attributes(
      outcome: "partial",
      incomplete_checks: [ { "name" => "exhale_provision", "reason" => "dependency_install_failed" } ]
    )
  end

  # @spec MAINT-020 MAINT-021 MAINT-022 MAINT-025
  it "persists findings and incomplete coverage from the agent report" do
    finding = {
      category: "obsolete_behavior", claim: "WorkflowA uses a retired callback", symbols: [ "WorkflowA" ],
      locations: [ { path: "app/workflows/a.rb", line: 18 } ], supporting_evidence: [ { source: "inspection" } ],
      contrary_evidence: [], evidence_source: "agent", analyzer_provenance: {}, raw_tool_confidence: nil,
      agent_assessment: "actionable", proposed_action: "Remove the callback", validation_plan: "Run workflow specs",
      verification_disposition: "unverified"
    }
    run.log!("stdout", report_output(findings: [ finding ],
      incomplete_checks: [ { name: "runtime trace", reason: "unavailable_service" } ],
      evidence: { "revision" => "abc123" }))

    described_class.new.execute(agent_run_id: run.id)

    report = run.reload.maintenance_report
    expect(report).to have_attributes(outcome: "partial", evidence: { "revision" => "abc123" })
    expect(report.incomplete_checks).to contain_exactly("name" => "runtime trace", "reason" => "unavailable_service")
    expect(report.finding_occurrences.sole).to have_attributes(claim: "WorkflowA uses a retired callback")
  end

  # @spec MAINT-022
  it "records malformed agent output as incomplete coverage" do
    run.log!("stdout", "Investigation finished, but no structured report was emitted.")

    described_class.new.execute(agent_run_id: run.id)

    expect(run.reload.maintenance_report).to have_attributes(outcome: "partial",
      incomplete_checks: [ { "name" => "agent_report", "reason" => "parse_failure" } ])
  end

  it "is idempotent for an already-finished run" do
    run.update!(status: "cancelled", completed_at: Time.current)

    result = described_class.new.execute(agent_run_id: run.id)

    expect(result[:agent_run_id]).to eq(run.id)
    expect(run.reload.status).to eq("cancelled")
    expect(run.maintenance_report).to have_attributes(outcome: "cancelled")
  end

  # @spec MAINT-023
  it "does not let concurrent cancellation overwrite a persisted report outcome" do
    run.log!("stdout", report_output)
    cancellation_finished = Queue.new
    cancellation = nil
    allow(MaintenanceReports::AgentReport).to receive(:parse).and_wrap_original do |method, *args|
      cancellation = Thread.new do
        TenantContext.with_system_access { run.class.find(run.id).cancel! }
        cancellation_finished << true
      end
      cancellation_finished.pop(timeout: 0.5)
      method.call(*args)
    end

    begin
      described_class.new.execute(agent_run_id: run.id)
    ensure
      cancellation&.join
    end

    expect(run.reload).to have_attributes(status: "completed")
    expect(run.maintenance_report).to have_attributes(outcome: "clean")
  end

  it "preserves the collected report evidence in the run logs" do
    run.log!("stdout", report_output)

    described_class.new.execute(agent_run_id: run.id)

    expect(run.reload.agent_run_logs.stdout.count).to eq(1)
  end

  # @spec MAINT-020
  it "fails when the agent modified source files" do
    result = described_class.new.execute(agent_run_id: run.id, has_changes: true)

    expect(result).to include(agent_run_id: run.id, success: false)
    expect(run.reload).to have_attributes(status: "failed", error_message: a_string_including("report-only"))
  end
end
