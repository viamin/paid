# frozen_string_literal: true

require "rails_helper"

# @spec CONTAINER-RUNTIME-035
# @spec CONTAINER-RUNTIME-036
RSpec.describe ExecutionResourceReconciliationJob do
  let(:job) { described_class.new }
  let(:runner_type) { "fake_runner" }
  let(:runner_class) do
    Class.new do
      def resource_kind = "container"
      def supports_tag_reconciliation? = true
      def list_resources_by_tags(tags:, resource_kind: nil) = []
      def cleanup_resource(resource:, force: false); end
    end
  end
  let(:runner) do
    instance_double(
      runner_class,
      resource_kind: "container",
      supports_tag_reconciliation?: true,
      list_resources_by_tags: [],
      cleanup_resource: nil
    )
  end
  let(:ownership_tags) do
    {
      "paid.account_id" => project.account_id.to_s,
      "paid.project_id" => project.id.to_s,
      "paid.run_id" => finished_run.id.to_s,
      "paid.created_at" => Time.current.utc.iso8601
    }
  end
  let(:managed_resource) do
    ExecutionRunners::ManagedResource.new(
      runner_type: runner_type,
      resource_kind: "container",
      identifier: "orphan-123",
      host: "cloud-a",
      ownership_tags: ownership_tags,
      metadata: {}
    )
  end
  let(:project) { create(:project) }
  let(:finished_run) { create(:agent_run, :completed, project: project) }

  before do
    allow(ExecutionRunners).to receive(:reconciliation_runners).and_return([ runner ])
    allow(ExecutionRunners).to receive(:for_type).with(runner_type).and_return(runner)
    allow(ExecutionRunners).to receive(:for_type).with("local_docker").and_call_original
  end

  def create_cleanup_request(provider_resource_id:)
    create(
      :execution_resource_cleanup,
      cleanup_project: project,
      agent_run: finished_run,
      runner_type: runner_type,
      resource_kind: "container",
      provider_resource_id: provider_resource_id,
      provider_resource_host: "cloud-a",
      ownership_tags: ownership_tags,
      next_attempt_at: 1.minute.ago
    )
  end

  def expect_pending_attempt(cleanup, attempts:)
    expect(cleanup.reload.status).to eq("pending")
    expect(cleanup.attempts).to eq(attempts)
  end

  it "discovers tagged orphan resources and cleans them up" do
    allow(runner).to receive(:list_resources_by_tags).and_return([ managed_resource ])

    job.perform

    cleanup = ExecutionResourceCleanup.order(:id).last
    expect(cleanup).to be_present
    expect(cleanup.status).to eq("completed")
    expect(runner).to have_received(:cleanup_resource).with(resource: managed_resource, force: true)
  end

  it "cleans up crash-window orphan intents whose handle was never persisted" do
    intent = create(
      :provisioning_intent,
      project: project,
      agent_run: finished_run,
      account: project.account,
      runner_type: runner_type,
      status: "created",
      provider_resource_id: "crash-window-1",
      provider_resource_host: "cloud-a",
      ownership_tags: ownership_tags
    )

    expect do
      job.perform
    end.to change(ExecutionResourceCleanup, :count).by(1)

    expect(runner).to have_received(:cleanup_resource).with(
      resource: have_attributes(identifier: "crash-window-1", host: "cloud-a"),
      force: true
    )
    expect(intent.reload.reconciled_at).to be_present
    expect(intent.status).to eq("failed")
  end

  it "retries transient cleanup failures via the durable queue and succeeds on the third pass" do
    call_count = 0
    allow(runner).to receive(:cleanup_resource) do
      call_count += 1
      raise ExecutionRunners::ProvisionError, "provider unavailable" if call_count < 3
    end

    freeze_time do
      create_cleanup_request(provider_resource_id: "retry-me")

      job.perform
      cleanup = ExecutionResourceCleanup.order(:id).last
      expect_pending_attempt(cleanup, attempts: 1)

      travel 6.minutes
      job.perform
      expect_pending_attempt(cleanup, attempts: 2)

      travel 16.minutes
      job.perform

      expect(cleanup.reload.status).to eq("completed")
      expect(call_count).to eq(3)
    end
  end
end
