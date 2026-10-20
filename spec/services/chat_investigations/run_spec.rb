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
  end
end
