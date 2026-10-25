# frozen_string_literal: true

require "rails_helper"

RSpec.describe Activities::RetainContainerActivity do
  let(:activity) { described_class.new }
  let(:project) { create(:project) }
  let(:container) { instance_double(Docker::Container, info: { "State" => { "Running" => true } }) }

  before do
    allow(Docker::Container).to receive(:get).with("abc123").and_return(container)
    allow(container).to receive(:stop).with(timeout: 10)
  end

  describe "#execute" do
    it "sets container_retained_until on the agent run" do
      agent_run = create(:agent_run, :running, project: project, container_id: "abc123")
      allow(activity).to receive(:disk_pressure?).and_return(false)

      freeze_time do
        result = activity.execute(agent_run_id: agent_run.id)

        expect(result[:retained]).to be true
        expect(result[:retained_until]).to be_present
        agent_run.reload
        expect(agent_run.container_retained_until).to eq(4.hours.from_now)
        expect(container).to have_received(:stop).with(timeout: 10)
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
      agent_run = create(:agent_run, :running, project: project, container_id: "abc123")
      allow(activity).to receive(:disk_pressure?).and_return(true)

      freeze_time do
        activity.execute(agent_run_id: agent_run.id)

        agent_run.reload
        expect(agent_run.container_retained_until).to eq(1.hour.from_now)
      end
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
