# frozen_string_literal: true

require "rails_helper"

RSpec.describe PageLoadRegressionFinding do
  let(:project) { create(:project) }

  # @spec PAGE-LOAD-REGRESSION-009
  it "allows only one open finding per pull request and route" do
    create(:page_load_regression_finding, project: project)

    expect {
      create(:page_load_regression_finding, project: project)
    }.to raise_error(ActiveRecord::RecordNotUnique)
  end

  # @spec PAGE-LOAD-REGRESSION-009
  it "allows a new open finding once the previous one is resolved" do
    finding = create(:page_load_regression_finding, project: project)
    finding.update!(status: "resolved", resolved_at: Time.current)

    expect {
      create(:page_load_regression_finding, project: project)
    }.not_to raise_error
  end

  # @spec PAGE-LOAD-FOLLOWUP-006
  it "reports exhaustion once attempts reach the cap" do
    finding = create(:page_load_regression_finding, project: project,
      followup_attempts: described_class::MAX_FOLLOWUP_ATTEMPTS - 1)

    expect(finding).not_to be_followup_exhausted

    finding.record_followup_attempt!

    expect(finding).to be_followup_exhausted
    expect(described_class.followup_eligible).to be_empty
  end

  # @spec PAGE-LOAD-FOLLOWUP-001
  it "scopes actionable open findings for a pull request" do
    actionable = create(:page_load_regression_finding, project: project, actionable: true)
    create(:page_load_regression_finding, project: project, route_name: "settings", actionable: false)

    expect(described_class.actionable.open_findings.where(pull_request_number: 42)).to contain_exactly(actionable)
  end

  # @spec PAGE-LOAD-FOLLOWUP-004
  it "exposes the route path on its evidence so the prompt can name the URL" do
    finding = create(:page_load_regression_finding, project: project, route_path: "/dashboard")

    expect(finding.evidence).to include("route_path" => "/dashboard")
  end
end
