# frozen_string_literal: true

require "rails_helper"

RSpec.describe PrerequisiteValidationJob do # @spec PREREQ-EVIDENCE-002 @spec PREREQ-EVIDENCE-007
  let(:account) { create(:account) }
  let(:project) { create(:project, account: account) }
  let(:issue) { create(:issue, project: project, github_state: "open") }
  let(:validation) do
    create(:prerequisite_validation, account: account, project: project, issue: issue, status: "pending")
  end
  let(:capability_report) do
    instance_double(Prerequisites::CapabilityReport::Report)
  end

  before do
    allow(Prerequisites::CapabilityReport).to receive(:call).and_return(capability_report)
    allow(Prerequisites::ExecuteValidation).to receive(:call)
  end

  it "builds the capability report and executes the validation within the tenant context" do
    described_class.perform_now(validation.id)

    expect(Prerequisites::CapabilityReport).to have_received(:call).with(project: project)
    expect(Prerequisites::ExecuteValidation).to have_received(:call)
      .with(validation, capability_report: capability_report)
  end

  it "never executes a validation that is no longer pending" do
    validation.update!(status: "cancelled", completed_at: Time.current)

    described_class.perform_now(validation.id)

    expect(Prerequisites::ExecuteValidation).not_to have_received(:call)
  end
end
