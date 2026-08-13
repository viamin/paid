# frozen_string_literal: true

require "rails_helper"

# RDR-055 conformance suite: proves the runner contract and its value objects
# can carry a create-PR workload on a backend that shares no filesystem with the
# control plane — no host bind mounts, no host worktree paths, no host-visible
# workspace, log, or heartbeat files.
#
# The suite drives the contract through a reference runner (see
# spec/support/runners/conformance_reference_runner.rb) that stands in for a
# future remote runner — Fly machine, Kubernetes job, remote Docker — whose
# only durable link to Paid is the persisted
# {ExecutionRunners::RunnerHandle}. That makes this file a conformance harness
# for the contract itself: it fails if the interface, the value objects, or the
# handle-persistence lane ever grow a host-storage requirement that only a
# same-host runner could satisfy.
#
# Today's Docker runner is held to the same bar: it consumes the "a
# no-shared-filesystem runner" shared examples in
# spec/services/execution_runners/local_docker_runner_spec.rb, so a regression
# in its no-shared-filesystem behavior fails there too.
#
# @spec CONTAINER-RUNTIME-007
# @spec CONTAINER-RUNTIME-008
# @spec CONTAINER-RUNTIME-009
# @spec CONTAINER-RUNTIME-011
RSpec.describe ExecutionRunners::Base do
  # Stands in for a remote backend (remote Docker, Swarm, and any future
  # non-local platform all report +supports_host_paths?+ as false).
  let(:backend) do
    instance_double(Containers::Backends::Base, identifier: "conformance-platform",
                    remote?: true, supports_host_paths?: false)
  end

  # A create-PR run with no worktree: the default lane, where the repository is
  # cloned inside the workload rather than shared from the host.
  let(:agent_run) { create(:agent_run, container_host: "conformance-platform", worktree_path: nil) }

  let(:run_spec) do
    ExecutionRunners::RunSpec.from_agent_run(
      agent_run,
      networking_policy: ExecutionRunners::NetworkingPolicy.proxy_restricted
    )
  end

  let(:runner) { ConformanceReferenceRunner.new }
  let(:valid_handle) { runner.provision(spec: run_spec) }

  it_behaves_like "an ExecutionRunner implementation"
  it_behaves_like "a no-shared-filesystem runner"

  describe "the create-PR spec built from a run without a worktree" do
    # @spec CONTAINER-RUNTIME-009
    it "asks for runner-owned storage instead of a host path" do
      expect(run_spec.workspace).to have_attributes(mode: :named_volume, reference: nil)
    end

    it "carries the run's environment without a host-visible workspace path" do
      handle = runner.provision(spec: run_spec)

      expect(handle.metadata).to eq(
        "agent_run_id" => agent_run.id, "environment" => agent_run.service_environment || {}
      )
    end
  end

  describe "recovery from the persisted handle" do
    # @spec CONTAINER-RUNTIME-008
    it "observes and tears down the environment from the DB-stored handle alone" do
      handle = runner.provision(spec: run_spec)
      agent_run.update!(runner_handle: handle.to_storage)

      recovered = ExecutionRunners::RunnerHandle.from_record(agent_run.reload)

      expect(recovered).to eq(handle)
      expect(runner.status(handle: recovered)).not_to be_not_found

      runner.cleanup(handle: recovered, force: true)

      expect(runner.status(handle: recovered)).to be_not_found
    end
  end

  describe "a legacy bind-mount workspace" do
    # @spec CONTAINER-RUNTIME-011
    it "cannot be provisioned by a runner without shared host storage" do
      bind_mount_spec = run_spec.with(
        workspace: ExecutionRunners::WorkspaceStrategy.bind_mount(reference: "/var/paid/worktrees/1")
      )

      expect { runner.provision(spec: bind_mount_spec) }
        .to raise_error(ExecutionRunners::ProvisionError, /shared host storage/)
    end
  end
end
