# frozen_string_literal: true

require "rails_helper"

RSpec.describe Activities::ProvisionContainerActivity do
  let(:activity) { described_class.new }
  let(:project) { create(:project) }
  let(:agent_run) { create(:agent_run, project: project) }
  let(:worktree_path) { Dir.mktmpdir("worktree") }
  let(:mock_container) do
    instance_double(
      Docker::Container,
      id: "abc123container",
      start: true,
      stop: true,
      delete: true,
      refresh!: true,
      info: { "State" => { "Running" => true, "ExitCode" => 0 } },
      exec: nil
    )
  end

  before do
    allow(Docker::Container).to receive(:create).and_return(mock_container)
    allow(Docker::Container).to receive(:get).and_raise(Docker::Error::NotFoundError)
    allow(Docker::Volume).to receive_messages(create: instance_double(Docker::Volume, remove: true),
      get: instance_double(Docker::Volume, remove: true))
    allow(NetworkPolicy).to receive_messages(ensure_network!: instance_double(Docker::Network),
      apply_firewall_rules: nil)
  end

  after do
    FileUtils.rm_rf(worktree_path) if worktree_path && Dir.exist?(worktree_path)
  end

  describe "#execute" do
    it "provisions a container for the agent run" do
      expect(agent_run).to receive(:ensure_proxy_token!).and_return("token")
      expect(agent_run).to receive(:provision_container)
      allow(AgentRun).to receive(:find).with(agent_run.id).and_return(agent_run)

      result = activity.execute(agent_run_id: agent_run.id)

      expect(result[:agent_run_id]).to eq(agent_run.id)
    end

    it "raises ActiveRecord::RecordNotFound for invalid agent_run_id" do
      expect {
        activity.execute(agent_run_id: -1)
      }.to raise_error(ActiveRecord::RecordNotFound)
    end

    # @spec EGRESS-POLICY-006
    it "snapshots the resolved egress policy on the run before provisioning" do
      activity.execute(agent_run_id: agent_run.id)

      snapshot = AgentRuns::EgressPolicy::Snapshot.from_record(agent_run.reload)
      derived_mode = Containers::Provision.networking_policy_for(agent_run: agent_run, project: project).mode.to_s
      expect(snapshot).not_to be_nil
      expect(snapshot.mode).to eq(derived_mode)
      expect(snapshot.destinations.map { |destination| destination["host"] }).to include("egress-gateway", "paid-proxy")
    end

    # @spec EGRESS-POLICY-006
    it "keeps the egress policy snapshot auditable when provisioning fails" do
      allow(AgentRun).to receive(:find).with(agent_run.id).and_return(agent_run)
      allow(agent_run).to receive(:ensure_proxy_token!).and_return("token")
      allow(agent_run).to receive(:provision_container)
        .and_raise(Containers::Provision::ProvisionError, "provision exploded")

      expect {
        activity.execute(agent_run_id: agent_run.id)
      }.to raise_error(Containers::Provision::ProvisionError)

      expect(AgentRuns::EgressPolicy::Snapshot.from_record(agent_run.reload)).not_to be_nil
    end

    # @spec EGRESS-POLICY-005
    it "fails closed before provisioning when an unsafe allowlist entry is rejected" do
      entry = create(:egress_allowlist_entry, account: project.account, host_pattern: "api.partner.com")
      entry.update_columns(host_pattern: "*") # bypass write-time validation

      allow(AgentRun).to receive(:find).with(agent_run.id).and_return(agent_run)
      allow(agent_run).to receive(:ensure_proxy_token!).and_return("token")
      expect(agent_run).not_to receive(:provision_container)

      expect {
        activity.execute(agent_run_id: agent_run.id)
      }.to raise_error(AgentRuns::EgressPolicy::Resolve::DeniedPolicyError, /wildcard/)

      snapshot = AgentRuns::EgressPolicy::Snapshot.from_record(agent_run.reload)
      expect(snapshot).to be_denied
    end

    it "does not create a second container when retried against a live container" do
      run = create(:agent_run, project: project, worktree_path: worktree_path, container_id: "existing-container")
      existing = instance_double(
        Docker::Container,
        id: "existing-container",
        refresh!: true,
        info: { "State" => { "Running" => true } }
      )
      allow(Docker::Container).to receive(:get).with("existing-container").and_return(existing)
      allow(AgentRun).to receive(:find).with(run.id).and_return(run)

      # Simulate a Temporal retry: execute the activity twice for the same run.
      expect(Docker::Container).not_to receive(:create)

      2.times { activity.execute(agent_run_id: run.id) }

      # No duplicate was provisioned — the live container is reused and the
      # recorded container_id is unchanged (orphan count is zero).
      expect(run.reload.container_id).to eq("existing-container")
    end
  end

  describe "#provision_with_heartbeat" do
    let(:mock_context) { instance_double(Temporalio::Activity::Context) }

    before do
      allow(mock_context).to receive(:heartbeat)
    end

    it "calls provision directly when no activity context is present" do
      allow(Temporalio::Activity::Context).to receive(:current_or_nil).and_return(nil)
      expect(agent_run).to receive(:provision_container).and_return(:result)

      expect(activity.send(:provision_with_heartbeat, agent_run)).to eq(:result)
    end

    it "returns the provisioning result and emits heartbeats while it runs" do
      allow(Temporalio::Activity::Context).to receive(:current_or_nil).and_return(mock_context)
      allow(agent_run).to receive(:provision_container) do
        sleep 0.15
        :provisioned
      end

      result = activity.send(:provision_with_heartbeat, agent_run, interval: 0.02)

      expect(result).to eq(:provisioned)
      expect(mock_context).to have_received(:heartbeat).with("provisioning").at_least(:once)
    end

    # A wedged Docker call (e.g. a stuck image pull) keeps the worker thread
    # alive but makes no progress. The heartbeat only proves the Ruby worker is
    # alive, so it keeps flowing and a heartbeat_timeout would never fire — a
    # stuck pull is therefore bounded by start_to_close, not by the heartbeat.
    # No heartbeat_timeout is configured on the workflow call site for this
    # reason (see AgentExecutionWorkflow#execute).
    it "keeps heartbeating while a wedged worker is alive (bounded by start_to_close, not heartbeat)" do
      allow(Temporalio::Activity::Context).to receive(:current_or_nil).and_return(mock_context)

      gate = Queue.new
      allow(agent_run).to receive(:provision_container) do
        gate.pop # simulate a wedged Docker call that never completes on its own
        :provisioned
      end

      heartbeat_count = 0
      allow(mock_context).to receive(:heartbeat) do
        heartbeat_count += 1
        # Release the wedged worker only after observing several heartbeats
        # that fired while it made zero progress.
        gate << :release if heartbeat_count >= 3
      end

      result = activity.send(:provision_with_heartbeat, agent_run, interval: 0.01, grace_seconds: 0.05)

      expect(result).to eq(:provisioned)
      expect(heartbeat_count).to be >= 3
    end

    it "propagates exceptions raised during provisioning" do
      allow(Temporalio::Activity::Context).to receive(:current_or_nil).and_return(mock_context)
      allow(agent_run).to receive(:provision_container).and_raise(Containers::Provision::ProvisionError, "boom")

      expect {
        activity.send(:provision_with_heartbeat, agent_run, interval: 0.02)
      }.to raise_error(Containers::Provision::ProvisionError, "boom")
    end

    it "re-raises CanceledError from heartbeat and stops the worker" do
      allow(Temporalio::Activity::Context).to receive(:current_or_nil).and_return(mock_context)
      allow(mock_context).to receive(:heartbeat).and_raise(Temporalio::Error::CanceledError, "canceled")
      allow(agent_run).to receive(:provision_container) { sleep 0.2 }

      expect {
        activity.send(:provision_with_heartbeat, agent_run, interval: 0.01)
      }.to raise_error(Temporalio::Error::CanceledError)
    end

    it "does not spuriously interrupt a worker that finishes within the grace window" do
      allow(Temporalio::Activity::Context).to receive(:current_or_nil).and_return(mock_context)
      allow(mock_context).to receive(:heartbeat).and_raise(Temporalio::Error::CanceledError, "canceled")
      finished = []
      allow(agent_run).to receive(:provision_container) { sleep 0.1; finished << true }

      expect {
        activity.send(:provision_with_heartbeat, agent_run, interval: 0.01, grace_seconds: 5)
      }.to raise_error(Temporalio::Error::CanceledError)

      # The worker ran to completion instead of being forcibly interrupted —
      # the grace-window join succeeded before escalation.
      expect(finished).to eq([ true ])
    end

    it "interrupts a stuck worker but still surfaces CanceledError" do
      allow(Temporalio::Activity::Context).to receive(:current_or_nil).and_return(mock_context)
      allow(mock_context).to receive(:heartbeat).and_raise(Temporalio::Error::CanceledError, "canceled")
      interrupted = []
      allow(agent_run).to receive(:provision_container) do
        sleep 10
      rescue Interrupt
        interrupted << true
        raise
      end

      expect {
        activity.send(:provision_with_heartbeat, agent_run, interval: 0.01, grace_seconds: 0.05)
      }.to raise_error(Temporalio::Error::CanceledError)

      # The worker outlived the grace window and was interrupted, yet the
      # propagating CanceledError was not masked by the worker's Interrupt.
      expect(interrupted).to eq([ true ])
    end

    it "recovers an in-flight container before Thread#kill on the last-resort path" do
      # Exercise drain_worker directly with a raw blocking thread (rather than
      # the with_connection-wrapped provision worker) so a forcibly killed
      # worker cannot leak a DB connection into the test pool. The worker
      # swallows Interrupt and stays alive past the grace window, forcing the
      # Thread#kill path that recover_in_flight_container! guards.
      worker = Thread.new do
        loop do
          begin
            sleep 5
          rescue Interrupt
            # swallowed — simulates a worker wedged in uninterruptible I/O
          end
        end
      end

      allow(agent_run).to receive(:recover_in_flight_container!).and_return("recovered-container")

      activity.send(:drain_worker, worker, canceled: true, grace_seconds: 0.05, agent_run: agent_run)

      # Thread#kill is asynchronous — it only schedules the worker to terminate,
      # so the worker may still be alive briefly after drain_worker returns. In
      # production this is intentional: a worker wedged in uninterruptible I/O
      # may never die, so joining after kill could block the activity. Here the
      # worker is in interruptible sleep (not truly wedged), so it terminates
      # promptly — wait for the scheduled termination before asserting instead
      # of relying on kill being synchronous.
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
      sleep(0.01) while worker.alive? && Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
      expect(worker).not_to be_alive
      # recover runs only on the Thread#kill path, proving the in-flight
      # container is recorded before the worker is forcibly terminated.
      expect(agent_run).to have_received(:recover_in_flight_container!)
    end
  end
end
