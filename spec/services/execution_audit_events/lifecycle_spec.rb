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

    it "does not link a resource ledger row for non-resource lifecycle events" do
      agent_run.update!(runner_handle: { "identifier" => "runner-handle-non-resource" })
      create(:execution_resource_ledger_entry, :active, :with_agent_run,
        entry_account: project.account, project: project, agent_run: agent_run,
        provider_resource_id: nil, runner_handle: { "identifier" => "runner-handle-non-resource" })

      event = described_class.record(
        event_name: "execution.runner_selected",
        actor_id: "spec",
        agent_run: agent_run
      )

      expect(event.metadata).not_to have_key("resource_ledger_id")
    end

    it "threads the temporal workflow id, request id, and runner handle id through metadata" do
      agent_run.update!(
        temporal_workflow_id: "wf-execution-123",
        runner_handle: { "identifier" => "runner-handle-meta" }
      )
      Current.request_id = "request-456"

      event = described_class.record(
        event_name: "execution.image_resolved",
        actor_id: "spec",
        agent_run: agent_run,
        resource_type: "container"
      )

      expect(event.metadata).to include(
        "temporal_workflow_id" => "wf-execution-123",
        "request_id" => "request-456",
        "runner_handle_id" => "runner-handle-meta"
      )
    ensure
      Current.request_id = nil
    end

    it "uses the explicit correlation_id when provided and prefers it over the temporal workflow id" do
      agent_run.update!(temporal_workflow_id: "wf-runner-corr")

      event = described_class.record(
        event_name: "execution.admitted",
        actor_id: "spec",
        agent_run: agent_run,
        correlation_id: "wf-explicit-correlation"
      )

      expect(event.correlation_id).to eq("wf-explicit-correlation")
      expect(event.metadata["temporal_workflow_id"]).to eq("wf-explicit-correlation")
    end

    # @spec EXECUTION-AUDIT-004
    it "passes through runner, backend, image_reference, and image_digest fields for provisioning events" do
      event = described_class.record(
        event_name: "execution.image_resolved",
        actor_id: "spec",
        agent_run: agent_run,
        backend: "docker-local",
        image_reference: "paid-agent:elixir",
        image_digest: "sha256:abc123def456",
        networking_policy: { mode: "proxy_restricted", firewall: true }
      )

      expect(event).to have_attributes(
        backend: "docker-local",
        image_reference: "paid-agent:elixir",
        image_digest: "sha256:abc123def456",
        network_policy: include("mode" => "proxy_restricted", "firewall" => true),
        event_version: 1
      )
    end

    # @spec EXECUTION-AUDIT-004
    it "falls back to credential class none when neither authority grants nor a firewall are present" do
      event = described_class.record(
        event_name: "execution.runner_selected",
        actor_id: "spec",
        agent_run: agent_run
      )

      expect(event.credential_classes).to eq([ ExecutionAuditEvent::CREDENTIAL_CLASS_NONE ])
    end

    it "derives credential classes from the agent run's authority grants" do
      agent_run.update!(authority_grants: {
        "grants" => [
          { "delivery" => "subscription_auth" },
          { "delivery" => "direct_outbound" }
        ]
      })

      event = described_class.record(
        event_name: "execution.credential_classes_granted",
        actor_id: "spec",
        agent_run: agent_run
      )

      expect(event.credential_classes).to contain_exactly(
        ExecutionAuditEvent::CREDENTIAL_CLASS_SUBSCRIPTION_AUTH,
        ExecutionAuditEvent::CREDENTIAL_CLASS_DIRECT_OUTBOUND
      )
    end

    it "defaults credential_classes to proxy_restricted when the policy has a firewall and no grants" do
      event = described_class.record(
        event_name: "execution.network_policy_granted",
        actor_id: "spec",
        agent_run: agent_run,
        networking_policy: { mode: "proxy_restricted", firewall: true }
      )

      expect(event.credential_classes).to include(ExecutionAuditEvent::CREDENTIAL_CLASS_PROXY_RESTRICTED)
    end

    it "leaves the correlation_id blank when the run has only the CLAIMED_SENTINEL temporal workflow id" do
      agent_run.update!(temporal_workflow_id: AgentRun::CLAIMED_SENTINEL)

      event = described_class.record(
        event_name: "execution.queued",
        actor_id: "spec",
        agent_run: agent_run
      )

      expect(event.correlation_id).to be_nil
      expect(event.metadata).not_to have_key("temporal_workflow_id")
    end

    it "resolves runner_key from the explicitly passed runner when one is provided" do
      runner = instance_double(Runner, runner_key: "claude")

      event = described_class.record(
        event_name: "execution.runner_selected",
        actor_id: "spec",
        agent_run: agent_run,
        runner: runner
      )

      expect(event.runner_key).to eq("claude")
    end

    it "resolves runner_key from the agent_run's persisted runner when no explicit runner is passed" do
      runner = create(:runner, runner_key: "codex", user: project.created_by)
      agent_run.update!(runner_id: runner.id)

      event = described_class.record(
        event_name: "execution.runner_selected",
        actor_id: "spec",
        agent_run: agent_run
      )

      expect(event.runner_key).to eq("codex")
    end

    it "accepts a NetworkingPolicy-shaped object and serializes its allow_destinations" do
      policy = ExecutionRunners::NetworkingPolicy.new(
        mode: :proxy_restricted,
        firewall: true,
        allow_destinations: [ { host: "registry.example.com", port: 443 }, { host: "proxy.paid.example", port: 443 } ]
      )

      event = described_class.record(
        event_name: "execution.network_policy_granted",
        actor_id: "spec",
        agent_run: agent_run,
        networking_policy: policy
      )

      expect(event.network_policy).to include(
        "mode" => "proxy_restricted",
        "firewall" => true
      )
      expect(event.network_policy["allow_destinations"]).to be_an(Array)
      expect(event.network_policy["allow_destinations"].length).to eq(2)
    end

    it "logs and returns nil when record! raises rather than propagating the error" do
      allow(ExecutionAuditEvent).to receive(:record!).and_raise(ActiveRecord::RecordInvalid)
      allow(Rails.logger).to receive(:error)

      result = described_class.record(
        event_name: "execution.image_resolved",
        actor_id: "spec",
        agent_run: agent_run
      )

      expect(result).to be_nil
      expect(Rails.logger).to have_received(:error).with(
        hash_including(
          message: "execution_audit.lifecycle_record_failed",
          event_name: "execution.image_resolved"
        )
      )
    end
  end
end
