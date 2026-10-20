# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChatInvestigations::Run do
  describe "experiment investigations" do
    it "completes when workspace provisioning readies the session" do # @spec QUESTION-EXPLORATION-010
      investigation = create(:chat_investigation, kind: "experiment", reserved_cost_cents: 10)
      investigation.created_by.add_role(:project_member, investigation.project)
      allow(Containers::ProvisionForChat).to receive(:call) do |chat_session:, **|
        chat_session.update!(container_capability: "ready", container_ready_at: Time.current)
      end

      described_class.call(investigation:)

      expect(investigation.reload).to have_attributes(
        status: "completed",
        result: "An isolated workspace is ready for this experiment.",
        reserved_cost_cents: 0
      )
    end

    it "fails the investigation when the workspace never becomes ready" do # @spec QUESTION-EXPLORATION-010
      investigation = create(:chat_investigation, kind: "experiment", reserved_cost_cents: 10)
      investigation.created_by.add_role(:project_member, investigation.project)
      allow(Containers::ProvisionForChat).to receive(:call)

      described_class.call(investigation:)

      expect(investigation.reload).to have_attributes(
        status: "failed",
        result: "Isolated workspace is unavailable",
        reserved_cost_cents: 0
      )
    end

    it "reuses an already ready workspace without provisioning a duplicate container" do # @spec QUESTION-EXPLORATION-010
      investigation = create(:chat_investigation, kind: "experiment", reserved_cost_cents: 10)
      investigation.created_by.add_role(:project_member, investigation.project)
      investigation.chat_session.update!(container_capability: "ready", container_ready_at: Time.current)
      allow(Containers::ProvisionForChat).to receive(:call)

      described_class.call(investigation:)

      expect(Containers::ProvisionForChat).not_to have_received(:call)
      expect(investigation.reload).to have_attributes(
        status: "completed",
        result: "An isolated workspace is ready for this experiment.",
        reserved_cost_cents: 0
      )
    end

    it "does not race an in-flight workspace provision" do # @spec QUESTION-EXPLORATION-010
      investigation = create(:chat_investigation, kind: "experiment", reserved_cost_cents: 10)
      investigation.created_by.add_role(:project_member, investigation.project)
      investigation.chat_session.update!(container_capability: "provisioning")
      allow(Containers::ProvisionForChat).to receive(:call)

      described_class.call(investigation:)

      expect(Containers::ProvisionForChat).not_to have_received(:call)
      expect(investigation.reload).to have_attributes(
        status: "failed",
        result: "Isolated workspace is unavailable",
        reserved_cost_cents: 0
      )
    end
  end

  describe "interrupted runs" do
    it "settles a re-entered running investigation as failed" do # @spec QUESTION-EXPLORATION-010
      investigation = create(:chat_investigation, kind: "research", status: "running",
        reserved_cost_cents: 80, started_at: 1.minute.ago)

      described_class.call(investigation:)

      expect(investigation.reload).to have_attributes(
        status: "failed",
        result: "Execution was interrupted before completion.",
        reserved_cost_cents: 0,
        finished_at: be_present
      )
    end

    it "releases the stranded reservation without charging the budget" do # @spec QUESTION-EXPLORATION-010
      investigation = create(:chat_investigation, kind: "research", status: "running",
        reserved_cost_cents: 80, started_at: 1.minute.ago)
      budget = create(:cost_budget, :hard_stop, :daily, project: investigation.project, limit_cents: 100)

      described_class.call(investigation:)

      expect(budget.reload.current_usage_cents).to eq(0)
    end
  end
end
