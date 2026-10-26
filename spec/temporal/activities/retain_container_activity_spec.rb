# frozen_string_literal: true

require "rails_helper"

RSpec.describe Activities::RetainContainerActivity do
  let(:activity) { described_class.new }
  let(:project) { create(:project) }
  let(:container_state) { { "State" => { "Running" => true } } }
  let(:container) { instance_double(Docker::Container, info: container_state) }

  before do
    allow(Docker::Container).to receive(:get).with("abc123").and_return(container)
    allow(container).to receive(:stop) { container_state["State"]["Running"] = false }
  end

  describe "#execute" do
    it "sets container_retained_until on the agent run" do
      agent_run = create(:agent_run, :failed, project: project, container_id: "abc123")
      allow(activity).to receive(:disk_pressure?).and_return(false)

      freeze_time do
        result = activity.execute(agent_run_id: agent_run.id)

        expect(result[:retained]).to be true
        expect(result[:retained_until]).to be_present
        agent_run.reload
        expect(agent_run.container_retained_until).to eq(4.hours.from_now)
        expect(container).to have_received(:stop).with("timeout" => 10)
      end
    end

    # @spec CONTAINER-RUNTIME-048
    it "does not record retention when Docker cannot stop the workload" do
      agent_run = create(:agent_run, :failed, project:, container_id: "abc123")
      allow(container).to receive(:stop).and_raise(Docker::Error::ServerError, "daemon unavailable")

      expect { activity.execute(agent_run_id: agent_run.id) }.to raise_error(Docker::Error::ServerError)
      expect(agent_run.reload.container_retained_until).to be_nil
    end

    # @spec CONTAINER-RUNTIME-048
    it "retains an already-stopped container without starting or deleting it" do
      agent_run = create(:agent_run, :failed, project:, container_id: "abc123")
      allow(container).to receive(:info).and_return("State" => { "Running" => false })
      allow(container).to receive(:delete)
      allow(container).to receive(:start)

      expect(activity.execute(agent_run_id: agent_run.id)[:retained]).to be(true)
      expect(container).not_to have_received(:stop)
      expect(container).not_to have_received(:delete)
      expect(container).not_to have_received(:start)
      expect(agent_run.reload.container_id).to eq("abc123")
    end

    it "returns retained: false when agent run has no container" do
      agent_run = create(:agent_run, :running, project: project, container_id: nil)

      result = activity.execute(agent_run_id: agent_run.id)

      expect(result[:retained]).to be false
    end

    it "returns retained: false when agent run does not exist" do
      result = activity.execute(agent_run_id: -1)

      expect(result[:retained]).to be false
    end

    it "shortens retention TTL under disk pressure" do
      agent_run = create(:agent_run, :failed, project: project, container_id: "abc123")
      allow(activity).to receive(:disk_pressure?).and_return(true)

      freeze_time do
        activity.execute(agent_run_id: agent_run.id)

        agent_run.reload
        expect(agent_run.container_retained_until).to eq(1.hour.from_now)
      end
    end

    # @spec CONTAINER-RUNTIME-048
    it "protects diagnostic data from the janitor while Docker is stopping" do
      agent_run = create(:agent_run, :failed, project:, container_id: "abc123")
      allow(container).to receive(:stop) do
        expect(agent_run.reload).to be_container_retained
        AgentRunResourceJanitorJob.perform_now(agent_run.id)
        container_state["State"]["Running"] = false
      end

      expect(activity.execute(agent_run_id: agent_run.id)[:retained]).to be(true)
    end

    # @spec CONTAINER-RUNTIME-048
    it "does not stop an active run even if a stale retention activity is delivered" do
      agent_run = create(:agent_run, :running, project:, container_id: "abc123")

      expect(activity.execute(agent_run_id: agent_run.id)[:retained]).to be(false)
      expect(container).not_to have_received(:stop)
      expect(agent_run.reload.container_retained_until).to be_nil
    end

    # @spec CONTAINER-RUNTIME-048
    it "restores an existing expiry when a stop fails" do
      old_expiry = 1.hour.from_now
      agent_run = create(:agent_run, :failed, project:, container_id: "abc123", container_retained_until: old_expiry)
      allow(container).to receive(:stop).and_raise(Docker::Error::ServerError, "stop failed")

      expect { activity.execute(agent_run_id: agent_run.id) }.to raise_error(Docker::Error::ServerError)
      expect(agent_run.reload.container_retained_until).to be_within(1.second).of(old_expiry)
    end

    # @spec CONTAINER-RUNTIME-048
    it "does not undo another retention update when a stop fails" do
      agent_run = create(:agent_run, :failed, project:, container_id: "abc123")
      newer_expiry = 5.hours.from_now
      allow(container).to receive(:stop) do
        agent_run.update!(container_retained_until: newer_expiry)
        raise Docker::Error::ServerError, "stop failed"
      end

      expect { activity.execute(agent_run_id: agent_run.id) }.to raise_error(Docker::Error::ServerError)
      expect(agent_run.reload.container_retained_until).to be_within(1.second).of(newer_expiry)
    end

    # @spec CONTAINER-RUNTIME-048
    it "detects a stop error swallowed by the real Docker client" do
      agent_run = create(:agent_run, :failed, project:, container_id: "abc123")
      connection = Docker::Connection.new("http://docker.example", {})
      allow(Docker).to receive(:connection).and_return(connection)
      allow(Docker::Container).to receive(:get).and_call_original
      allow(connection).to receive(:get).with("/containers/abc123/json", {}).and_return(
        { "Id" => "abc123", "State" => { "Running" => true } }.to_json
      )
      allow(connection).to receive(:post).and_raise(Docker::Error::ServerError, "daemon failed")

      expect { activity.execute(agent_run_id: agent_run.id) }.to raise_error(Docker::Error::ServerError)
      expect(agent_run.reload.container_retained_until).to be_nil
    end

    # @spec CONTAINER-RUNTIME-048
    it "sends Docker's stop timeout parameter and confirms the fresh stopped state" do
      agent_run = create(:agent_run, :failed, project:, container_id: "abc123")
      connection = Docker::Connection.new("http://docker.example", {})
      allow(Docker).to receive(:connection).and_return(connection)
      allow(Docker::Container).to receive(:get).and_call_original
      allow(connection).to receive(:get).with("/containers/abc123/json", {}).and_return(
        { "Id" => "abc123", "State" => { "Running" => true } }.to_json,
        { "Id" => "abc123", "State" => { "Running" => false } }.to_json
      )
      allow(connection).to receive(:post).and_return("")

      expect(activity.execute(agent_run_id: agent_run.id)[:retained]).to be(true)
      expect(connection).to have_received(:post).with("/containers/abc123/stop", { "t" => 10 },
        hash_including(read_timeout: 15, write_timeout: 15))
      expect(connection).to have_received(:get).with("/containers/abc123/json", {}).twice
    end
  end

  describe "#disk_pressure?" do
    it "returns true when disk usage exceeds threshold" do
      status = instance_double(Process::Status, success?: true)
      allow(Open3).to receive(:capture3)
        .with("df", "--output=pcent", "/")
        .and_return([ "Use%\n 90%\n", "", status ])

      expect(activity.send(:disk_pressure?)).to be true
    end

    it "returns false when disk usage is below threshold" do
      status = instance_double(Process::Status, success?: true)
      allow(Open3).to receive(:capture3)
        .with("df", "--output=pcent", "/")
        .and_return([ "Use%\n 50%\n", "", status ])

      expect(activity.send(:disk_pressure?)).to be false
    end

    it "returns false when the command fails" do
      status = instance_double(Process::Status, success?: false)
      allow(Open3).to receive(:capture3)
        .with("df", "--output=pcent", "/")
        .and_return([ "", "error", status ])

      expect(activity.send(:disk_pressure?)).to be false
    end

    it "returns false when Open3 raises" do
      allow(Open3).to receive(:capture3).and_raise(Errno::ENOENT)

      expect(activity.send(:disk_pressure?)).to be false
    end
  end
end
