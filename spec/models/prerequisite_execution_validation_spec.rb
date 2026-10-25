# frozen_string_literal: true

require "rails_helper"

RSpec.describe PrerequisiteExecutionValidation do # @spec PREREQ-EXEC-006 @spec PREREQ-EXEC-011 @spec PREREQ-EXEC-014
  describe "status taxonomy" do
    it "distinguishes active, terminal, succeeded, unavailable, and cancelled states" do
      expect(described_class::ACTIVE_STATUSES).to eq(%w[pending preparing running])
      expect(described_class::TERMINAL_STATUSES).to contain_exactly(
        "succeeded", "partial", "failed", "cancelled", "unavailable"
      )
    end

    # @spec PREREQ-EXEC-011
    it "maps every outcome to a matching AgentRun terminal status" do
      expect(described_class.agent_run_status_for("succeeded")).to eq("completed")
      expect(described_class.agent_run_status_for("partial")).to eq("completed")
      expect(described_class.agent_run_status_for("failed")).to eq("failed")
      expect(described_class.agent_run_status_for("unavailable")).to eq("failed")
      expect(described_class.agent_run_status_for("cancelled")).to eq("cancelled")
    end

    it "answers state predicates and marks evidence stale" do
      validation = create(:prerequisite_execution_validation, :unavailable)
      expect(validation).to be_terminal
      expect(validation).to be_unavailable
      expect(validation).not_to be_succeeded

      validation.mark_stale!
      expect(validation.reload).to be_stale
    end
  end

  describe "step helpers" do
    it "exposes planned step keys, per-step results, and missing requirements" do
      validation = create(:prerequisite_execution_validation, :succeeded)

      expect(validation.planned_step_keys).to include("native_analyzer")
      expect(validation.step_result("native_analyzer")["exit_code"]).to eq(0)
      expect(validation.step_succeeded?("native_analyzer")).to be(true)
      expect(validation.missing_requirements).to eq([])
    end
  end

  describe "one active attempt per issue" do
    it "enforces a single active validation per prerequisite issue at the database level" do
      validation = create(:prerequisite_execution_validation, status: "running")

      expect {
        create(:prerequisite_execution_validation, issue: validation.issue, status: "pending")
      }.to raise_error(ActiveRecord::RecordNotUnique)
    end

    it "permits a new attempt once the previous attempt is terminal" do
      validation = create(:prerequisite_execution_validation, :unavailable)

      expect {
        create(:prerequisite_execution_validation, issue: validation.issue, status: "pending")
      }.not_to raise_error
    end
  end
end
