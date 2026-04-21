# frozen_string_literal: true

require "rails_helper"

RSpec.describe Activities::CheckQualityGateActivity do
  subject(:activity) { described_class.new }

  let(:project) do
    create(:project, quality_gate_settings: {
      "enabled" => true,
      "composite_score_threshold" => 0.6,
      "min_recent_runs" => 3,
      "rolling_window_size" => 3,
      "metric_thresholds" => {}
    })
  end

  it "allows runs when quality gates are disabled" do
    project.update!(quality_gate_settings: { "enabled" => false })

    result = activity.execute(project_id: project.id)

    expect(result).to include(allowed: true, reason: "quality_gates_disabled")
  end

  it "blocks automatic runs when the rolling average breaches the threshold" do
    create_metric(0.4)
    create_metric(0.5)
    create_metric(0.3)

    result = activity.execute(project_id: project.id)

    expect(result).to include(allowed: false, blocked: true, reason: "quality_gate_breached")
    expect(result[:breaches]).to include(hash_including(metric: "composite_score", current: 0.4, threshold: 0.6))
  end

  it "allows runs when there is not enough recent data" do
    create_metric(0.1)

    result = activity.execute(project_id: project.id)

    expect(result).to include(allowed: true, reason: "insufficient_data", sample_size: 1, min_required: 3)
  end

  it "bypasses manual runs" do
    agent_run = create(:agent_run, :manual, project: project)
    create_metric(0.1)
    create_metric(0.1)
    create_metric(0.1)

    result = activity.execute(project_id: project.id, agent_run_id: agent_run.id)

    expect(result).to include(allowed: true, bypassed: true, reason: "manual_run")
  end

  it "bypasses priority issue runs" do
    issue = create(:issue, project: project, labels: [ "P1" ])
    create_metric(0.1)
    create_metric(0.1)
    create_metric(0.1)

    result = activity.execute(project_id: project.id, issue_id: issue.id)

    expect(result).to include(allowed: true, bypassed: true, reason: "priority_run")
  end

  it "bypasses priority pull request runs" do
    issue = create(:issue, project: project, labels: [ "bug" ])
    pull_request = create(:issue, :pull_request, project: project, github_number: 42, labels: [ "P2" ])
    create_metric(0.1)
    create_metric(0.1)
    create_metric(0.1)

    result = activity.execute(
      project_id: project.id,
      issue_id: issue.id,
      source_pull_request_number: pull_request.github_number
    )

    expect(result).to include(allowed: true, bypassed: true, reason: "priority_run")
  end

  it "checks the current pull request labels when the activity instance is reused" do
    priority_pr = create(:issue, :pull_request, project: project, github_number: 42, labels: [ "P2" ])
    regular_pr = create(:issue, :pull_request, project: project, github_number: 43, labels: [ "bug" ])
    create_metric(0.1)
    create_metric(0.1)
    create_metric(0.1)

    priority_result = activity.execute(
      project_id: project.id,
      source_pull_request_number: priority_pr.github_number
    )
    regular_result = activity.execute(
      project_id: project.id,
      source_pull_request_number: regular_pr.github_number
    )

    expect(priority_result).to include(allowed: true, bypassed: true, reason: "priority_run")
    expect(regular_result).to include(allowed: false, blocked: true, reason: "quality_gate_breached")
  end

  it "records the gate result in workflow state" do
    create_metric(0.9)
    create_metric(0.8)
    create_metric(0.7)

    activity.execute(
      project_id: project.id,
      workflow_id: "agent-workflow-1",
      workflow_type: "AgentExecutionWorkflow"
    )

    state = WorkflowState.find_by!(temporal_workflow_id: "agent-workflow-1")
    expect(state.result_data.dig("quality_gate", "reason")).to eq("quality_gate_passed")
    expect(state.project).to eq(project)
  end

  def create_metric(score)
    run = create(:agent_run, :completed, project: project)
    create(:quality_metric, :automated, agent_run: run, composite_score: score)
  end
end
