# frozen_string_literal: true

require "rails_helper"

# Negative controls for the RDR-057 no-shared-filesystem conformance suite
# (spec/support/shared_examples/no_shared_filesystem_conformance.rb). Each
# example feeds the conformance checks a deliberately non-conforming runner,
# handle, manifest, or contract surface and asserts the checks reject it. If
# one of these controls stops failing, the conformance suite has lost its
# teeth against shared-host-storage regressions.
#
# @spec CONTAINER-RUNTIME-019
RSpec.describe NoSharedFilesystemConformance do
  let(:conformance_run) do
    create(
      :agent_run,
      goal: "create_pr",
      branch_name: "feature/conformance",
      base_commit_sha: "cafebabecafebabecafebabecafebabecafebabe",
      result_commit_sha: "f00dcafef00dcafef00dcafef00dcafef00dcafe",
      verification_result: {
        "status" => "passed",
        "artifacts" => [ { "kind" => "trace", "url" => "https://artifacts.test/conformance.zip" } ]
      }
    )
  end
  let(:conformance_networking_policy) { ExecutionRunners::NetworkingPolicy.proxy_restricted }
  let(:conformance_spec) do
    ExecutionRunners::RunSpec.from_agent_run(
      conformance_run, networking_policy: conformance_networking_policy
    )
  end
  let(:host_worktree) { "/var/paid/worktrees/#{conformance_run.id}" }

  describe "a runner that requires shared host storage" do
    let(:bind_mount_only_runner) do
      Class.new(ExecutionRunners::Base) do
        def provision(spec:)
          unless spec.workspace.bind_mount?
            raise ExecutionRunners::ProvisionError, "runner requires a host worktree bind mount"
          end

          ExecutionRunners::RunnerHandle.new(
            runner_type: :shared_host, identifier: "host-1", host: nil,
            workspace_ref: spec.workspace.reference, metadata: {}
          )
        end
      end
    end

    it "cannot provision the host-path-free create-PR scenario" do
      expect { bind_mount_only_runner.new.provision(spec: conformance_spec) }
        .to raise_error(ExecutionRunners::ProvisionError, /bind mount/)
    end

    it "leaks the host path into its handle when handed one, so the check catches it" do
      host_spec = ExecutionRunners::RunSpec.from_agent_run(
        conformance_run.tap { |run| run.worktree_path = host_worktree },
        networking_policy: conformance_networking_policy
      )
      expect(host_spec.workspace).to be_bind_mount

      handle = bind_mount_only_runner.new.provision(spec: host_spec)

      expect(described_class.host_path_strings(handle.as_json)).to include(host_worktree)
    end
  end

  describe "a persisted handle that leaks host storage" do
    it "is flagged by the host-path check" do
      handle = ExecutionRunners::RunnerHandle.new(
        runner_type: :shared_host, identifier: "host-1", host: nil,
        workspace_ref: host_worktree,
        metadata: { "worktree_path" => host_worktree }
      )

      expect(described_class.host_path_strings(handle.as_json))
        .to contain_exactly(host_worktree)
    end
  end

  describe "manifests that reference host storage" do
    it "flags an input manifest whose workspace carries a host reference" do
      manifest = conformance_spec.input_manifest
      leaking = ExecutionRunners::ExecutionInputManifest.new(
        **manifest.to_h.merge(
          execution: manifest.execution.merge(
            "workspace" => manifest.execution["workspace"].merge("reference" => host_worktree)
          )
        )
      )

      expect(described_class.host_path_strings(leaking.as_json)).to include(host_worktree)
    end

    it "flags an output manifest that points durable outputs at host files" do
      manifest = ExecutionRunners::ExecutionResult.success.output_manifest(agent_run: conformance_run)
      leaking = ExecutionRunners::ExecutionOutputManifest.new(
        **manifest.to_h.merge(
          artifacts: manifest.artifacts.merge(
            "binary_artifacts" => [
              { "lane" => "object_storage", "kind" => "diff",
                "locator" => { "path" => host_worktree } }
            ]
          )
        )
      )

      expect(described_class.host_path_strings(leaking.as_json)).to include(host_worktree)
    end
  end

  describe "a contract surface that speaks Docker exec or bind mounts" do
    it "flags the forbidden tokens" do
      tokens = %w[provision exec_in_container bind_mount_path start]

      expect(described_class.forbidden_surface_tokens(tokens))
        .to contain_exactly("exec_in_container", "bind_mount_path")
    end

    it "does not flag provider-neutral lifecycle vocabulary" do
      tokens = %w[provision start status cancel cleanup handle spec command heartbeat_path execution]

      expect(described_class.forbidden_surface_tokens(tokens)).to be_empty
    end
  end

  describe "host-path detection scope" do
    it "allows only the declarative in-container workspace mount point" do
      payload = { "workspace" => { "mount_point" => "/workspace" } }

      expect(described_class.host_path_strings(payload, allowed: [ "/workspace" ])).to be_empty
      expect(described_class.host_path_strings(payload)).to eq([ "/workspace" ])
    end

    it "ignores URLs and opaque runner references" do
      payload = {
        "repository_url" => "https://github.com/acme/widgets",
        "workspace_ref" => "paid-workspace-42",
        "artifact_url" => "https://artifacts.test/trace.zip"
      }

      expect(described_class.host_path_strings(payload)).to be_empty
    end
  end
end
