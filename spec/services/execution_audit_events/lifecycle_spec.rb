# frozen_string_literal: true

require "rails_helper"

# @spec EXECUTION-AUDIT-005
RSpec.describe ExecutionAuditEvents::Lifecycle do
  let(:project) { create(:project) }
  let(:agent_run) { create(:agent_run, project: project) }

  describe ".record" do
    it "links the resource ledger row by provider resource id when one matches" do
      ledger_entry = create(:execution_resource_ledger_entry, :active, :with_agent_run,
        entry_account: project.account, project: project, agent_run: agent_run,
        provider_resource_id: "container-123")

      event = described_class.record(
        event_name: "execution.resource_provisioned",
        actor_id: "spec",
        agent_run: agent_run,
        resource_type: "container",
        resource_id: "container-123"
      )

      expect(event.metadata["resource_ledger_id"]).to eq(ledger_entry.id)
    end

    # @spec EXECUTION-AUDIT-005
    it "falls back to the agent run's persisted runner handle when no provider resource id is given" do
      agent_run.update!(runner_handle: { "identifier" => "runner-handle-456" })
      ledger_entry = create(:execution_resource_ledger_entry, :active, :with_agent_run,
        entry_account: project.account, project: project, agent_run: agent_run,
        provider_resource_id: nil, runner_handle: { "identifier" => "runner-handle-456" })

      event = described_class.record(
        event_name: "execution.resource_provision_requested",
        actor_id: "spec",
        agent_run: agent_run,
        resource_type: "container"
      )

      expect(event.metadata["resource_ledger_id"]).to eq(ledger_entry.id)
    end

    it "falls back to the runner handle when the provider resource id does not match any ledger row" do
      agent_run.update!(runner_handle: { "identifier" => "runner-handle-789" })
      ledger_entry = create(:execution_resource_ledger_entry, :active, :with_agent_run,
        entry_account: project.account, project: project, agent_run: agent_run,
        provider_resource_id: nil, runner_handle: { "identifier" => "runner-handle-789" })

      event = described_class.record(
        event_name: "execution.resource_provisioned",
        actor_id: "spec",
        agent_run: agent_run,
        resource_type: "container",
        resource_id: "unmatched-resource-id"
      )

      expect(event.metadata["resource_ledger_id"]).to eq(ledger_entry.id)
    end

    it "does not set a resource_ledger_id when neither the resource id nor the runner handle match" do
      event = described_class.record(
        event_name: "execution.resource_provisioned",
        actor_id: "spec",
        agent_run: agent_run,
        resource_type: "container",
        resource_id: "unmatched-resource-id"
      )

      expect(event.metadata).not_to have_key("resource_ledger_id")
    end

    # @spec EXECUTION-AUDIT-005
    it "falls back to a ProvisioningIntent row by provider resource id when no ledger entry matches" do
      intent = create(:provisioning_intent, intent_project: project, agent_run: agent_run,
        provider_resource_id: "container-999", status: ProvisioningIntent::STATUS_CREATED)

      event = described_class.record(
        event_name: "execution.resource_provisioned",
        actor_id: "spec",
        agent_run: agent_run,
        resource_type: "container",
        resource_id: "container-999"
      )

      expect(event.metadata["resource_ledger_id"]).to eq(intent.id)
    end

    it "falls back to a ProvisioningIntent row by runner handle when no ledger entry or provider resource id matches" do
      agent_run.update!(runner_handle: { "identifier" => "runner-handle-999" })
      intent = create(:provisioning_intent, intent_project: project, agent_run: agent_run,
        runner_handle: { "identifier" => "runner-handle-999" }, status: ProvisioningIntent::STATUS_LINKED)

      event = described_class.record(
        event_name: "execution.resource_provisioned",
        actor_id: "spec",
        agent_run: agent_run,
        resource_type: "container"
      )

      expect(event.metadata["resource_ledger_id"]).to eq(intent.id)
    end

    it "prefers a matching ExecutionResourceLedgerEntry over a ProvisioningIntent row" do
      ledger_entry = create(:execution_resource_ledger_entry, :active, :with_agent_run,
        entry_account: project.account, project: project, agent_run: agent_run,
        provider_resource_id: "container-both")
      create(:provisioning_intent, intent_project: project, agent_run: agent_run,
        provider_resource_id: "container-both", status: ProvisioningIntent::STATUS_CREATED)

      event = described_class.record(
        event_name: "execution.resource_provisioned",
        actor_id: "spec",
        agent_run: agent_run,
        resource_type: "container",
        resource_id: "container-both"
      )

      expect(event.metadata["resource_ledger_id"]).to eq(ledger_entry.id)
    end
  end
end
