# frozen_string_literal: true

# frozen_string: true

require "rails_helper"

RSpec.describe Prerequisites::CancelValidation do # @spec PREREQ-EVIDENCE-007
  let(:account) { create(:account) }
  let(:project) { create(:project, account: account) }
  let(:issue) { create(:issue, project: project, github_state: "open") }
  let(:status) { "pending" }
  let(:validation) do
    create(:prerequisite_validation, account: account, project: project, issue: issue, status: status)
  end

  def cancel!
    described_class.call(validation.reload)
  end

  it "cancels a running validation and preserves its recorded status as terminal" do
    validation.update!(status: "running", started_at: Time.current)

    result = cancel!

    expect(result).to be_success
    expect(validation.reload.status).to eq("cancelled")
    expect(validation.completed_at).to be_present
  end

  it "cancels a pending validation without execution, recording the skipped check" do
    result = cancel!

    expect(result).to be_success
    validation.reload
    expect(validation.status).to eq("cancelled")
    expect(validation.result.dig("checks", "native_analyzer", "reason")).to include("Cancelled before execution started")
  end

  it "refuses an already-terminal validation" do
    validation.update!(status: "succeeded", completed_at: Time.current)

    result = cancel!

    expect(result).not_to be_success
    expect(result.code).to eq(:not_active)
    expect(validation.reload.status).to eq("succeeded")
  end
end
