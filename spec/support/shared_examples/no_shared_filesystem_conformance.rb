# frozen_string_literal: true

# Conformance suite proving a runner satisfies RDR-057's no-shared-filesystem
# execution model. The suite drives the complete normal create-PR lifecycle —
# clone, run, log capture, artifact output, result manifest, cleanup — through
# the provider-neutral ExecutionRunners contract only:
#
# - code transport is the input manifest's Git lane (no shared host storage);
# - durable outputs travel on the object-storage and control-plane API lanes;
# - the persisted handle and both manifests carry no host filesystem paths;
# - the contract surface carries no Docker exec / bind-mount vocabulary.
#
# It fails when a runner requires shared host storage for normal create-PR
# execution: provisioning the host-path-free scenario must succeed, and any
# host path leaking into the persisted handle or the manifests breaks the
# assertions below.
#
# Expected `let` bindings:
#
#   runner          — an instance of the concrete runner class, with its
#                     execution platform stubbed so provision/start/status/
#                     cleanup succeed and #start returns stdout output
#   conformance_run — a persisted AgentRun describing a normal create-PR
#                     execution: goal "create_pr", branch_name and
#                     base_commit_sha set, no worktree_path, and a
#                     verification_result carrying a durable artifact URL
#                     (the post-execution state the output manifest derives
#                     from)
#
# The suite derives the RunSpec itself via RunSpec.from_agent_run so every
# runner conforms to the same canonical, host-path-free scenario.
#
# @spec CONTAINER-RUNTIME-019
RSpec.shared_examples "a no-shared-filesystem runner" do
  let(:conformance_networking_policy) { ExecutionRunners::NetworkingPolicy.proxy_restricted }
  let(:conformance_spec) do
    ExecutionRunners::RunSpec.from_agent_run(
      conformance_run, networking_policy: conformance_networking_policy
    )
  end
  let(:conformance_command) { "paid-conformance-agent" }

  describe "canonical create-PR scenario" do
    it "derives a host-path-free workspace strategy" do
      expect(conformance_run.worktree_path).to be_nil
      expect(conformance_spec.workspace).not_to be_bind_mount
      expect(conformance_spec.workspace.reference).to be_nil
    end
  end

  describe "lifecycle without host path assumptions" do
    it "provisions, runs, captures output, manifests results, and cleans up" do
      handle = runner.provision(spec: conformance_spec)
      expect(handle).to be_a(ExecutionRunners::RunnerHandle)

      result = runner.start(handle: handle, command: conformance_command, timeout: 60,
        startup_timeout: 30, idle_timeout: 30, abort_patterns: nil, preparation: nil,
        heartbeat_path: nil)

      expect(result).to be_success
      # Logs cross the boundary through the contract, not shared files.
      expect(result.stdout).to be_present

      manifest = result.output_manifest(agent_run: conformance_run)
      expect(manifest).to be_a(ExecutionRunners::ExecutionOutputManifest)
      expect(manifest.result_summary.fetch("success")).to be(true)
      expect(manifest.result_summary.fetch("stdout_bytes")).to be_positive

      expect(runner.running?(handle: handle)).to be_in([ true, false ])
      expect(runner.status(handle: handle)).to be_a(ExecutionRunners::ExecutionStatus)

      # Cleanup is idempotent: a second call for a torn-down handle is a no-op.
      expect {
        runner.cleanup(handle: handle, force: true)
        runner.cleanup(handle: handle, force: true)
      }.not_to raise_error
    end

    it "yields at least one streamed chunk through the start block" do
      handle = runner.provision(spec: conformance_spec)

      streamed = []
      runner.start(handle: handle, command: conformance_command, timeout: 60,
        startup_timeout: 30, idle_timeout: 30, abort_patterns: nil, preparation: nil,
        heartbeat_path: nil) { |stream, chunk| streamed << [ stream, chunk ] }

      # The runner must yield at least one chunk; an empty stream would mean
      # the runner is buffering (or worse, dropping) output that should travel
      # on the control-plane API lane, not through shared host storage.
      expect(streamed).not_to be_empty
      expect(streamed).to all(satisfy { |stream, chunk| %i[stdout stderr].include?(stream) && chunk.is_a?(String) })
    end

    it "keeps host filesystem paths out of the persisted handle" do
      handle = runner.provision(spec: conformance_spec)

      expect(handle.workspace_ref).not_to match(NoSharedFilesystemConformance::HOST_PATH_PATTERN)
      expect(NoSharedFilesystemConformance.host_path_strings(handle.as_json)).to be_empty
    end
  end

  describe "code transport" do
    it "clones over the Git lane with a declarative workspace and no host reference" do
      manifest = conformance_spec.input_manifest

      checkout = manifest.lanes.fetch("git").find { |ref| ref["kind"] == "repository_checkout" }
      expect(checkout).to be_present
      expect(checkout.fetch("locator")).to include(
        "repo_full_name" => conformance_run.project.full_name,
        "branch_name" => conformance_run.branch_name,
        "base_commit_sha" => conformance_run.base_commit_sha
      )
      expect(manifest.execution.fetch("workspace")).to eq(
        "mode" => conformance_spec.workspace.mode.to_s,
        "mount_point" => conformance_spec.workspace.mount_point
      )
      expect(NoSharedFilesystemConformance.host_path_strings(
               manifest.as_json, allowed: [ conformance_spec.workspace.mount_point ]
             )).to be_empty
    end
  end

  describe "durable outputs" do
    it "emits artifacts through object storage and logs through the control-plane API" do
      manifest = ExecutionRunners::ExecutionResult.success(stdout: "conformance", exit_code: 0)
                                        .output_manifest(agent_run: conformance_run)

      binary = manifest.artifacts.fetch("binary_artifacts")
      expect(binary).to be_present
      expect(binary).to all(include("lane" => "object_storage"))
      expect(binary.map { |entry| entry.dig("locator", "url") }).to all(be_present)
      expect(manifest.lanes.fetch("object_storage")).to be_present

      expect(manifest.log_refs).to include(
        hash_including("lane" => "control_plane_api", "kind" => "agent_run_logs")
      )
      expect(manifest.lanes.fetch("git")).to include(hash_including("kind" => "git_output"))
      expect(manifest.artifacts.fetch("code_outputs")).to contain_exactly(manifest.git_output)
      expect(manifest.git_output).to include(
        "branch_name" => conformance_run.branch_name,
        "result_commit_sha" => conformance_run.result_commit_sha
      )
      expect(manifest.lanes.fetch("credentials")).to be_empty
      expect(NoSharedFilesystemConformance.host_path_strings(manifest.as_json)).to be_empty
    end
  end

  describe "contract surface" do
    it "keeps Docker exec and bind-mount concepts off the runner contract" do
      tokens = NoSharedFilesystemConformance.contract_surface_tokens

      expect(NoSharedFilesystemConformance.forbidden_surface_tokens(tokens)).to be_empty
    end
  end
end
