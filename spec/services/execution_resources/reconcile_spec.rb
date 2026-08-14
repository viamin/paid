# frozen_string_literal: true

require "rails_helper"

# @spec CONTAINER-RUNTIME-018
# @spec CONTAINER-RUNTIME-019
RSpec.describe ExecutionResources::Reconcile do
  let(:account) { create(:account) }
  let(:project) { create(:project, account: account) }
  let(:agent_run) { create(:agent_run, :completed, project: project) }

  let(:handle) do
    ExecutionRunners::RunnerHandle.new(
      runner_type: :local_docker,
      identifier: "runner-container-123",
      host: "local",
      workspace_ref: "paid-workspace-#{agent_run.id}",
      metadata: {
        "agent_run_id" => agent_run.id,
        "worktree_path" => nil,
        "environment" => {}
      }
    )
  end

  let(:runner_class) do
    Class.new do
      attr_accessor :resources, :supports_listing, :fail_cleanup
      attr_accessor :fail_handle_cleanup
      attr_reader :cleaned_identifiers, :cleaned_handles

      def initialize
        @resources = []
        @supports_listing = true
        @fail_cleanup = false
        @fail_handle_cleanup = false
        @cleaned_identifiers = []
        @cleaned_handles = []
      end

      def supports_resource_listing?
        supports_listing
      end

      def list_resources(host: nil)
        resources
      end

      def cleanup_resource(resource:)
        raise StandardError, "cleanup failed" if fail_cleanup

        cleaned_identifiers << resource.identifier
      end

      def cleanup(handle:, force: false)
        raise StandardError, "cleanup failed" if fail_handle_cleanup

        cleaned_handles << handle.identifier
      end
    end
  end
  let(:runner) { runner_class.new }
  let(:runner_resolver) { ->(runner_type:, host:) { runner } }
  let(:inventory_targets) { [ { runner_type: "local_docker", host: "local" } ] }

  before do
    agent_run.update!(container_id: handle.identifier, container_host: handle.host)
  end

  it "marks an active ledger row cleaned when the provider no longer reports it" do
    resource = create(:execution_resource, project: project, agent_run: agent_run,
      identifier: handle.identifier, host: handle.host, runner_handle: handle.to_storage)

    result = reconcile(scope: ExecutionResource.where(id: resource.id))

    expect(result.checked).to eq(1)
    expect(resource.reload).to be_cleaned
  end

  it "adopts a tagged provider resource with no active ledger row and cleans it up" do
    runner.resources = [ orphaned_workspace_resource ]

    result = reconcile(scope: ExecutionResource.none)

    adopted = ExecutionResource.find_by(identifier: "paid-workspace-orphan")
    expect(result.adopted).to eq(1)
    expect(runner.cleaned_identifiers).to include("paid-workspace-orphan")
    expect(adopted).to be_present
    expect(adopted).to be_cleaned
    expect(adopted.adopted_at).to be_present
  end

  it "does not adopt a tagged provider resource for an unfinished agent run" do
    agent_run.update!(status: "running")
    runner.resources = [ orphaned_workspace_resource ]

    result = reconcile(scope: ExecutionResource.none)

    expect(result.adopted).to eq(0)
    expect(runner.cleaned_identifiers).to be_empty
    expect(ExecutionResource.find_by(identifier: "paid-workspace-orphan")).to be_nil
  end

  it "retries cleanup_pending resources with durable backoff when cleanup fails" do
    resource = create(:execution_resource, project: project, agent_run: agent_run,
      identifier: handle.identifier, host: handle.host, runner_handle: handle.to_storage,
      state: "cleanup_pending", next_cleanup_at: 1.minute.ago)
    runner.resources = [ tracked_resource(resource_type: "environment", identifier: handle.identifier) ]
    runner.fail_handle_cleanup = true

    result = reconcile(scope: ExecutionResource.where(id: resource.id))

    expect(result.failures).to eq(1)
    expect(resource.reload).to be_cleanup_pending
    expect(resource.cleanup_attempts).to eq(1)
    expect(resource.next_cleanup_at).to be > Time.current
  end

  it "degrades to handle-based cleanup with reduced confidence when the provider cannot list" do
    resource = create(:execution_resource, project: project, agent_run: agent_run,
      identifier: handle.identifier, host: handle.host, runner_handle: handle.to_storage,
      state: "cleanup_pending", next_cleanup_at: 1.minute.ago)
    runner.supports_listing = false

    result = reconcile(scope: ExecutionResource.where(id: resource.id))

    expect(result.reduced_confidence).to eq(1)
    expect(runner.cleaned_handles).to eq([ handle.identifier ])
    expect(resource.reload).to be_cleaned
    expect(resource.reduced_confidence).to be(true)
  end

  def tracked_resource(resource_type:, identifier:, tags: nil)
    ExecutionRunners::TrackedResource.new(
      runner_type: :local_docker,
      resource_type: resource_type,
      identifier: identifier,
      host: "local",
      workspace_ref: identifier,
      tags: tags || {
        "paid.agent_run_id" => agent_run.id.to_s,
        "paid.project_id" => project.id.to_s
      },
      metadata: {}
    )
  end

  def orphaned_workspace_resource
    tracked_resource(
      resource_type: "workspace",
      identifier: "paid-workspace-orphan",
      tags: {
        "paid.agent_run_id" => agent_run.id.to_s,
        "paid.project_id" => project.id.to_s,
        "paid.resource" => "workspace_volume"
      }
    )
  end

  def reconcile(scope:)
    described_class.new(
      scope: scope,
      runner_resolver: runner_resolver,
      inventory_targets: inventory_targets
    ).call
  end
end
