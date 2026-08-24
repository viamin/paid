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

  # @spec PAGE-LOAD-FOLLOWUP-001
  it "scopes actionable open findings for a pull request" do
    actionable = create(:page_load_regression_finding, project: project, actionable: true)
    create(:page_load_regression_finding, project: project, route_name: "settings", actionable: false)

    expect(described_class.actionable.open_findings.where(pull_request_number: 42)).to contain_exactly(actionable)
  end
end
