# frozen_string_literal: true

require "rails_helper"

RSpec.describe AgentRunResourceJanitorJob do
  let(:backend) { instance_double(Containers::Backends::Base) }

  before do
    allow(Containers).to receive(:backend_for).and_return(backend)
  end

  describe "#perform" do
    context "when agent run is finished" do
      let(:agent_run) { create(:agent_run, :completed) }

      it "attempts to remove the container when container_id is present" do
        agent_run.update_columns(container_id: "abc123")
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
      end

      it "removes the workspace volume for non-worktree runs" do
        volume = instance_double(Docker::Volume, remove: true)
        allow(backend).to receive(:get_volume)
          .with("paid-workspace-#{agent_run.id}", host: agent_run.container_host)
          .and_return(volume)
        allow(backend).to receive(:delete_volume).with(volume)

        described_class.new.perform(agent_run.id)

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
      end

      it "re-raises Docker errors during volume cleanup so retry_on can retry" do
        allow(backend).to receive(:get_volume)
          .and_raise(Docker::Error::DockerError, "daemon unavailable")

        expect { described_class.new.perform(agent_run.id) }
          .to raise_error(Docker::Error::DockerError, "daemon unavailable")
      end

      it "skips volume cleanup for worktree-based runs" do
        agent_run.update_columns(worktree_path: "/tmp/worktree")
        allow(backend).to receive(:get_volume)

        described_class.new.perform(agent_run.id)

        expect(backend).not_to have_received(:get_volume)
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
