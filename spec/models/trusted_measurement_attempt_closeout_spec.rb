# frozen_string_literal: true

require "rails_helper"

RSpec.describe TrustedMeasurementAttempt do
  let(:attempt) { create(:trusted_measurement_attempt, :succeeded) }
  let!(:run) do
    create(:agent_run, :completed, project: attempt.project, issue: attempt.issue,
      closeout_measurement_attempt: attempt)
  end

  # @spec STAGED-CLOSEOUT-ADOPTION-005
  it "keeps a historical run while removing a deleted source issue's measurement link" do
    attempt.issue.destroy!

    expect(described_class.exists?(attempt.id)).to be(false)
    expect(run.reload.closeout_measurement_attempt_id).to be_nil
  end

  # @spec STAGED-CLOSEOUT-ADOPTION-005
  it "removes the owning project without a closeout measurement foreign-key failure" do
    project = attempt.project
    project.destroy!

    expect(Project.exists?(project.id)).to be(false)
    expect(described_class.exists?(attempt.id)).to be(false)
    expect(AgentRun.exists?(run.id)).to be(false)
  end
end
