# frozen_string_literal: true

require "rails_helper"

RSpec.describe AgentRunResourceJanitorJob do # @spec CONTAINER-RUNTIME-032
  let(:backend) { instance_double(Containers::Backends::Base) }

  before do
    allow(Containers).to receive(:backend_for).and_return(backend)
  end

  describe "#perform" do
    context "when agent run is finished" do
      let(:agent_run) { create(:agent_run, :completed) }
      let!(:resource) do
        create(:execution_resource, project: agent_run.project, agent_run: agent_run,
          identifier: "abc123", host: agent_run.workspace_volume_host)
      end

      it "attempts to remove the container when container_id is present" do
        agent_run.update_columns(
          container_id: "abc123",
          container_host: "local",
          provisioning_started_at: 2.hours.ago,
          started_at: 90.minutes.ago,
          completed_at: 1.hour.ago
        )
        container = instance_double(Docker::Container, stop: true, delete: true)
        allow(backend).to receive(:get_container).with("abc123").and_return(container)
        allow(backend).to receive(:stop_container).with(container, timeout: 10)
        allow(backend).to receive(:delete_container).with(container, force: true, v: true)
        allow(backend).to receive(:get_volume).and_raise(Docker::Error::NotFoundError)

        described_class.new.perform(agent_run.id)

        expect(backend).to have_received(:get_container).with("abc123")
        expect(backend).to have_received(:stop_container).with(container, timeout: 10)
        expect(backend).to have_received(:delete_container).with(container, force: true, v: true)
        expect(agent_run.reload.container_id).to be_nil
        expect(agent_run.execution_usage).to be_present
        expect(agent_run.execution_usage.provider_resource_id).to eq("abc123")
        expect(agent_run.execution_usage.termination_reason).to eq("completed")
      end

      it "removes the workspace volume for non-worktree runs" do
        volume = instance_double(Docker::Volume, remove: true)
        allow(backend).to receive(:get_volume)
          .with("paid-workspace-#{agent_run.id}", host: agent_run.workspace_volume_host)
          .and_return(volume)
        allow(backend).to receive(:delete_volume).with(volume)

        described_class.new.perform(agent_run.id)

        expect(backend).to have_received(:delete_volume).with(volume)
      end

      it "cleans up the volume on the planned host when container_host is blank" do
        agent_run.update_columns(
          container_id: nil,
          container_host: nil,
          external_metadata: { "planned_container_host" => "remote" }
        )

        volume = instance_double(Docker::Volume, remove: true)
        allow(Containers).to receive(:backend_for).with("remote").and_return(backend)
        allow(backend).to receive(:get_volume)
          .with("paid-workspace-#{agent_run.id}", host: "remote")
          .and_return(volume)
        allow(backend).to receive(:delete_volume).with(volume)

        described_class.new.perform(agent_run.id)

        expect(Containers).to have_received(:backend_for).with("remote")
        expect(backend).to have_received(:get_volume)
          .with("paid-workspace-#{agent_run.id}", host: "remote")
        expect(backend).to have_received(:delete_volume).with(volume)
      end

      it "is a no-op when container and volume are already gone" do
        allow(backend).to receive(:get_volume).and_raise(Docker::Error::NotFoundError)

        expect { described_class.new.perform(agent_run.id) }.not_to raise_error
      end

      it "re-raises Docker errors during container cleanup so retry_on can retry" do
        agent_run.update_columns(container_id: "abc123")
        allow(backend).to receive(:get_container)
          .and_raise(Docker::Error::DockerError, "daemon unavailable")
        allow(backend).to receive(:get_volume).and_raise(Docker::Error::NotFoundError)

        expect { described_class.new.perform(agent_run.id) }
          .to raise_error(Docker::Error::DockerError, "daemon unavailable")
        expect(resource.reload).to be_cleanup_pending
        expect(resource.cleanup_attempts).to eq(1)
        expect(resource.last_cleanup_error_class).to eq("Docker::Error::DockerError")
      end

      it "re-raises Docker errors during volume cleanup so retry_on can retry" do
        allow(backend).to receive(:get_volume)
          .and_raise(Docker::Error::DockerError, "daemon unavailable")

        expect { described_class.new.perform(agent_run.id) }
          .to raise_error(Docker::Error::DockerError, "daemon unavailable")
        expect(resource.reload).to be_cleanup_pending
        expect(resource.cleanup_attempts).to eq(1)
      end

      it "skips volume cleanup for worktree-based runs" do
        agent_run.update_columns(worktree_path: "/tmp/worktree")
        allow(backend).to receive(:get_volume)

        described_class.new.perform(agent_run.id)

        expect(backend).not_to have_received(:get_volume)
        expect(resource.reload).to be_cleaned
      end

      it "backfills execution usage on a re-run after teardown already happened" do # @spec EXEC-USAGE-009
        # Simulates the self-healing path: a previous janitor pass cleaned
        # the resource but record_execution_usage failed transiently, so
        # the run still has no ExecutionUsage row. On this re-run
        # container_id is nil, the volume is already gone, and the
        # tracked resource is already cleaned — every prior cleanup gate
        # returns false, so the only path that can still record the
        # missing usage row is an unconditional attempt to record.
        agent_run.update_columns(
          container_id: nil,
          container_host: "local",
          provisioning_started_at: 2.hours.ago,
          started_at: 90.minutes.ago,
          completed_at: 1.hour.ago
        )
        resource.mark_cleaned!
        allow(backend).to receive(:get_volume).and_raise(Docker::Error::NotFoundError)

        described_class.new.perform(agent_run.id)

        usage = agent_run.reload.execution_usage
        expect(usage).to be_present
        expect(usage.termination_reason).to eq("completed")
        expect(usage.provider_resource_id).to be_nil
        expect(usage.runner_backend).to eq("local")
      end
    end

    context "when agent run has an unexpired container retention TTL" do
      let(:agent_run) { create(:agent_run, :failed, container_retained_until: 2.hours.from_now) }

      it "does not attempt any cleanup" do
        agent_run.update_columns(container_id: "abc123")
        allow(backend).to receive(:get_container)
        allow(backend).to receive(:get_volume)

        described_class.new.perform(agent_run.id)

        expect(backend).not_to have_received(:get_container)
        expect(backend).not_to have_received(:get_volume)
      end
    end

    context "when agent run has an expired container retention TTL" do
      let(:agent_run) { create(:agent_run, :failed, container_retained_until: 1.hour.ago) }

      it "proceeds with cleanup" do
        agent_run.update_columns(container_id: "abc123")
        container = instance_double(Docker::Container, stop: true, delete: true)
        allow(backend).to receive(:get_container).with("abc123").and_return(container)
        allow(backend).to receive(:stop_container).with(container, timeout: 10)
        allow(backend).to receive(:delete_container).with(container, force: true, v: true)
        allow(backend).to receive(:get_volume).and_raise(Docker::Error::NotFoundError)

        described_class.new.perform(agent_run.id)

        expect(backend).to have_received(:delete_container).with(container, force: true, v: true)
        expect(agent_run.reload.container_id).to be_nil
      end
    end

    context "when agent run is still active" do
      let(:agent_run) { create(:agent_run, status: "running") }

      it "does not attempt any cleanup" do
        allow(backend).to receive(:get_container)
        allow(backend).to receive(:get_volume)

        described_class.new.perform(agent_run.id)

        expect(backend).not_to have_received(:get_container)
        expect(backend).not_to have_received(:get_volume)
      end
    end

    context "when agent run is claimed but still queued" do
      let(:agent_run) { create(:agent_run, status: "queued", temporal_workflow_id: "workflow-123") }

      it "does not attempt any cleanup" do
        allow(backend).to receive(:get_container)
        allow(backend).to receive(:get_volume)

        described_class.new.perform(agent_run.id)

        expect(backend).not_to have_received(:get_container)
        expect(backend).not_to have_received(:get_volume)
      end
    end

    context "when agent run does not exist" do
      it "returns without error" do
        expect { described_class.new.perform(-1) }.not_to raise_error
      end
    end
  end
end
