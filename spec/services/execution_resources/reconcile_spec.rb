# frozen_string_literal: true

require "rails_helper"

# @spec CONTAINER-RUNTIME-030
# @spec CONTAINER-RUNTIME-031
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

  it "leaves an active ledger row active when the provider listing is missing but the owning run is still in progress" do
    agent_run.update!(status: "running")
    resource = create(:execution_resource, project: project, agent_run: agent_run,
      identifier: handle.identifier, host: handle.host, runner_handle: handle.to_storage)

    result = reconcile(scope: ExecutionResource.where(id: resource.id))

    expect(result.checked).to eq(1)
    expect(result.cleaned).to eq(0)
    expect(result.reduced_confidence).to eq(1)
    resource.reload
    expect(resource).to be_active
    expect(resource).not_to be_cleaned
    expect(resource.reduced_confidence).to be(true)
    expect(resource.reconciled_at).to be_present
    # The owning agent_run's container references must remain intact so the
    # live link to the container is not severed mid-execution.
    expect(agent_run.reload.container_id).to eq(handle.identifier)
    expect(agent_run.container_host).to eq(handle.host)
  end

  it "leaves an active ledger row active when the provider listing is missing but the finished run is retained" do
    agent_run.update!(container_retained_until: 2.hours.from_now)
    resource = create(:execution_resource, project: project, agent_run: agent_run,
      identifier: handle.identifier, host: handle.host, runner_handle: handle.to_storage)

    result = reconcile(scope: ExecutionResource.where(id: resource.id))

    expect(result.checked).to eq(1)
    expect(result.cleaned).to eq(0)
    expect(result.reduced_confidence).to eq(1)
    resource.reload
    expect(resource).to be_active
    expect(resource).not_to be_cleaned
    expect(resource.reduced_confidence).to be(true)
    expect(agent_run.reload.container_id).to eq(handle.identifier)
    expect(agent_run.container_host).to eq(handle.host)
  end

  it "marks an active ledger row cleaned when the provider listing is missing and the owning run has no agent_run" do
    resource = ExecutionResource.create!(
      account: account,
      project: project,
      agent_run: nil,
      resource_type: "environment",
      state: "active",
      runner_type: "local_docker",
      identifier: handle.identifier,
      host: handle.host,
      runner_handle: handle.to_storage,
      tags: { "paid.project_id" => project.id.to_s }
    )

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

  it "does not adopt or destroy a tagged provider resource for a finished but retained agent run" do
    agent_run.update!(container_retained_until: 2.hours.from_now)
    runner.resources = [ orphaned_workspace_resource ]

    result = reconcile(scope: ExecutionResource.none)

    expect(result.adopted).to eq(0)
    expect(runner.cleaned_identifiers).to be_empty
    expect(ExecutionResource.find_by(identifier: "paid-workspace-orphan")).to be_nil
  end

  it "adopts an orphan without linking agent_run when the run already owns a ledger row of that type, and still cleans it up" do
    create(:execution_resource, project: project, agent_run: agent_run,
      resource_type: "environment", state: "cleaned", identifier: "known-container", host: "local")
    leaked = tracked_resource(resource_type: "environment", identifier: "leaked-container")
    runner.resources = [ leaked ]

    result = reconcile(scope: ExecutionResource.none)

    leaked_resource = ExecutionResource.find_by(identifier: "leaked-container")
    expect(result.adopted).to eq(1)
    expect(result.failures).to eq(0)
    expect(leaked_resource).to be_cleaned
    expect(leaked_resource.agent_run_id).to be_nil
    expect(runner.cleaned_identifiers).to include("leaked-container")
  end

  it "does not confuse a differently-runner_type ledger row sharing host/identifier/resource_type when adopting" do
    other_project = create(:project, account: account)
    other_agent_run = create(:agent_run, :completed, project: other_project)
    contract_resource = create(:execution_resource, project: other_project, agent_run: other_agent_run,
      runner_type: "contract", host: "local", identifier: "shared-id", resource_type: "environment")
    leaked = tracked_resource(resource_type: "environment", identifier: "shared-id")
    runner.resources = [ leaked ]

    result = reconcile(scope: ExecutionResource.none)

    adopted = ExecutionResource.find_by(runner_type: "local_docker", identifier: "shared-id", host: "local")
    expect(result.adopted).to eq(1)
    expect(adopted).to be_present
    expect(adopted.id).not_to eq(contract_resource.id)
    expect(adopted.agent_run_id).to eq(agent_run.id)
    # The pre-existing contract-runner row must remain untouched: it is a
    # distinct ledger identity ((runner_type, host, identifier)) and must not
    # be adopted or repurposed just because it shares host/identifier/type.
    expect(contract_resource.reload.agent_run_id).to eq(other_agent_run.id)
  end

  it "keeps reconciling remaining orphans when adopting one races into a RecordNotUnique conflict" do
    create(:execution_resource, project: project, agent_run: agent_run,
      resource_type: "environment", state: "cleaned", identifier: "known-container", host: "local")
    leaked = tracked_resource(resource_type: "environment", identifier: "leaked-container")
    runner.resources = [ leaked, orphaned_workspace_resource ]

    reconciler = described_class.new(scope: ExecutionResource.none, runner_resolver: runner_resolver, inventory_targets: inventory_targets)
    # Force the TOCTOU race the rescue defends against: adoptable_agent_run's
    # exists? check can pass and still lose to a concurrent reconciliation
    # pass inserting the conflicting row before this save! runs.
    allow(reconciler).to receive(:adoptable_agent_run).and_wrap_original do |original, run:, resource:, resource_type:, listing_context:|
      resource_type == "environment" ? run : original.call(run:, resource:, resource_type:, listing_context:)
    end

    result = reconciler.call

    expect(result.failures).to eq(1)
    expect(result.adopted).to eq(1)
    expect(ExecutionResource.find_by(identifier: "leaked-container")).to be_nil
    expect(ExecutionResource.find_by(identifier: "paid-workspace-orphan")).to be_cleaned
  end

  it "preloads adoption ownership and owner records per group instead of querying per orphan" do
    runner.resources = [
      tracked_resource(resource_type: "environment", identifier: "orphan-environment"),
      orphaned_workspace_resource
    ]

    sql = capture_sql do
      reconcile(scope: ExecutionResource.none)
    end

    expect(sql.grep(/FROM "agent_runs"/).size).to eq(1)
    expect(sql.grep(/FROM "projects"/).size).to eq(2)
    expect(sql.grep(/SELECT 1 AS one FROM "execution_resources"/)).to be_empty
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

  it "does not retry cleanup_pending resources before their next_cleanup_at" do
    resource = create(:execution_resource, project: project, agent_run: agent_run,
      identifier: handle.identifier, host: handle.host, runner_handle: handle.to_storage,
      state: "cleanup_pending", next_cleanup_at: 10.minutes.from_now, cleanup_attempts: 1)
    runner.resources = [ tracked_resource(resource_type: "environment", identifier: handle.identifier) ]
    runner.fail_handle_cleanup = true

    result = reconcile(scope: ExecutionResource.where(id: resource.id))

    expect(result.failures).to eq(0)
    expect(runner.cleaned_handles).to be_empty
    expect(resource.reload).to have_attributes(
      state: "cleanup_pending",
      cleanup_attempts: 1
    )
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

  it "isolates a group whose listing raises so other groups still reconcile" do
    other_project = create(:project, account: account)
    other_agent_run = create(:agent_run, :completed, project: other_project)
    healthy_resource = create(:execution_resource, project: other_project, agent_run: other_agent_run,
      identifier: "healthy-container", host: "other-host")

    failing_runner = runner_class.new
    failing_runner.define_singleton_method(:list_resources) { |host: nil| raise ExecutionRunners::ProvisionError, "listing failed" }
    healthy_runner = runner_class.new

    resolver = lambda { |runner_type:, host:| host == "local" ? failing_runner : healthy_runner }
    targets = [ { runner_type: "local_docker", host: "local" }, { runner_type: "local_docker", host: "other-host" } ]

    resource = create(:execution_resource, project: project, agent_run: agent_run,
      identifier: handle.identifier, host: "local", runner_handle: handle.to_storage)

    result = described_class.new(
      scope: ExecutionResource.where(id: [ resource.id, healthy_resource.id ]),
      runner_resolver: resolver,
      inventory_targets: targets
    ).call

    expect(result.failures).to eq(1)
    expect(result.checked).to eq(1)
    expect(healthy_resource.reload).to be_cleaned
    expect(resource.reload).to be_active
  end

  it "fails a group instead of resolving an unknown runner_type to the Docker runner" do
    # @spec CONTAINER-RUNTIME-031
    resource = create(:execution_resource, project: project, agent_run: agent_run,
      runner_type: "contract", identifier: "contract-resource", host: "local")

    result = described_class.new(
      scope: ExecutionResource.where(id: resource.id),
      inventory_targets: [ { runner_type: "contract", host: "local" } ]
    ).call

    expect(result.failures).to eq(1)
    expect(result.checked).to eq(0)
    expect(resource.reload).to be_active
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

  def capture_sql
    queries = []
    callback = lambda do |_name, _start, _finish, _id, payload|
      sql = payload[:sql]
      next if payload[:name] == "SCHEMA"
      next if sql.match?(/\A(?:BEGIN|COMMIT|ROLLBACK|SAVEPOINT|RELEASE SAVEPOINT)/)

      queries << sql
    end

    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
      yield
    end

    queries
  end
end
