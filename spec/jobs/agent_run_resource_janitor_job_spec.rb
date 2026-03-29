# frozen_string_literal: true

require "rails_helper"

RSpec.describe AgentRunResourceJanitorJob do
  describe "#perform" do
    context "when agent run is finished" do
      let(:agent_run) { create(:agent_run, :completed) }

      it "attempts to remove the container when container_id is present" do
        agent_run.update_columns(container_id: "abc123")
        container = instance_double(Docker::Container, stop: true, delete: true)
        allow(Docker::Container).to receive(:get).with("abc123").and_return(container)
        allow(Docker::Volume).to receive(:get).and_raise(Docker::Error::NotFoundError)

        described_class.new.perform(agent_run.id)

        expect(container).to have_received(:stop).with(timeout: 10)
        expect(container).to have_received(:delete).with(force: true, v: true)
        expect(agent_run.reload.container_id).to be_nil
      end

      it "removes the workspace volume for non-worktree runs" do
        volume = instance_double(Docker::Volume, remove: true)
        allow(Docker::Volume).to receive(:get)
          .with("paid-workspace-#{agent_run.id}")
          .and_return(volume)

        described_class.new.perform(agent_run.id)

        expect(volume).to have_received(:remove)
      end

      it "is a no-op when container and volume are already gone" do
        allow(Docker::Volume).to receive(:get).and_raise(Docker::Error::NotFoundError)

        expect { described_class.new.perform(agent_run.id) }.not_to raise_error
      end

      it "re-raises Docker errors during container cleanup so retry_on can retry" do
        agent_run.update_columns(container_id: "abc123")
        allow(Docker::Container).to receive(:get)
          .and_raise(Docker::Error::DockerError, "daemon unavailable")
        allow(Docker::Volume).to receive(:get).and_raise(Docker::Error::NotFoundError)

        expect { described_class.new.perform(agent_run.id) }
          .to raise_error(Docker::Error::DockerError, "daemon unavailable")
      end

      it "re-raises Docker errors during volume cleanup so retry_on can retry" do
        allow(Docker::Volume).to receive(:get)
          .and_raise(Docker::Error::DockerError, "daemon unavailable")

        expect { described_class.new.perform(agent_run.id) }
          .to raise_error(Docker::Error::DockerError, "daemon unavailable")
      end

      it "skips volume cleanup for worktree-based runs" do
        agent_run.update_columns(worktree_path: "/tmp/worktree")
        allow(Docker::Volume).to receive(:get)

        described_class.new.perform(agent_run.id)

        expect(Docker::Volume).not_to have_received(:get)
      end
    end

    context "when agent run is still active" do
      let(:agent_run) { create(:agent_run, status: "running") }

      it "does not attempt any cleanup" do
        allow(Docker::Container).to receive(:get)
        allow(Docker::Volume).to receive(:get)

        described_class.new.perform(agent_run.id)

        expect(Docker::Container).not_to have_received(:get)
        expect(Docker::Volume).not_to have_received(:get)
      end
    end

    context "when agent run does not exist" do
      it "returns without error" do
        expect { described_class.new.perform(-1) }.not_to raise_error
      end
    end
  end
end
