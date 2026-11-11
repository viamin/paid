# frozen_string_literal: true

require "rails_helper"

RSpec.describe RunCollectorBatchJob do
  let(:project) { create(:project) }
  let(:commit_sha) { "a" * 40 }
  let(:github_client) { instance_double(GithubClient) }

  before do
    allow(GithubClient).to receive(:new).and_return(github_client)
    allow(github_client).to receive(:ref)
      .and_return(Struct.new(:object).new(Struct.new(:sha).new(commit_sha)))
  end

  # @spec KNOWLEDGE-014
  it "serializes with legacy full collection for the same project commit" do
    batch = described_class.new(project.id, commit_sha)
    continuation = RunCollectorContinuationJob.new(project.id, commit_sha)
    legacy = RunCollectorsJob.new(project.id, commit_sha)

    expect(batch.good_job_concurrency_key).to eq(legacy.good_job_concurrency_key)
    expect(continuation.good_job_concurrency_key).to eq(legacy.good_job_concurrency_key)
    expect(RunCollectorContinuationJob.good_job_concurrency_config).not_to have_key(:enqueue_limit)
  end

  # @spec KNOWLEDGE-014
  it "rejects a duplicate initial request while accepting a continuation", :good_job do
    original_batch_adapter = described_class.queue_adapter
    original_continuation_adapter = RunCollectorContinuationJob.queue_adapter
    described_class.queue_adapter = GoodJob::Adapter.new(execution_mode: :external)
    RunCollectorContinuationJob.queue_adapter = GoodJob::Adapter.new(execution_mode: :external)

    described_class.perform_later(project.id, commit_sha)
    duplicate = described_class.perform_later(project.id, commit_sha)
    continuation = RunCollectorContinuationJob.perform_later(project.id, commit_sha,
      collector_index: 1, collector_types: %w[first second])

    expect(duplicate).to be(false)
    expect(continuation).to be_successfully_enqueued
    expect(GoodJob::Job.where(concurrency_key: continuation.good_job_concurrency_key, finished_at: nil).count).to eq(2)
  ensure
    described_class.queue_adapter = original_batch_adapter
    RunCollectorContinuationJob.queue_adapter = original_continuation_adapter
  end

  # @spec KNOWLEDGE-014
  it "runs one collector type per job and finalizes only after the last type" do
    allow(Knowledge::CollectorRunner).to receive_messages(
      registry: { "first" => Object, "second" => Object }, finalize_collection: true
    )
    allow(Knowledge::ContainerizedRunner).to receive(:available?).and_return(false)
    allow(Knowledge::CollectorRunner).to receive(:call) do |options:, **|
      { results: [ { collector_type: options.fetch(:collector_types).first, status: "completed" } ] }
    end
    continuations = []
    allow(RunCollectorContinuationJob).to receive(:perform_later) { |*args, **kwargs| continuations << [ args, kwargs ] }

    described_class.new.perform(project.id, commit_sha)

    expect(Knowledge::CollectorRunner).to have_received(:call).once
    expect(Knowledge::CollectorRunner).not_to have_received(:finalize_collection)
    expect(project.reload.knowledge_status).to eq("collecting")

    args, kwargs = continuations.shift
    RunCollectorContinuationJob.new.perform(*args, **kwargs)

    expect(Knowledge::CollectorRunner).to have_received(:call).twice
    expect(Knowledge::CollectorRunner).to have_received(:finalize_collection).once
    expect(project.reload.knowledge_status).to eq("ready")
  end

  # @spec KNOWLEDGE-014
  it "passes a collector file cursor to its continuation" do
    allow(Knowledge::CollectorRunner).to receive_messages(
      registry: { "tree_sitter" => Object },
      call: { results: [ { collector_type: "tree_sitter", status: "in_progress", cursor: "app/a.rb" } ] }
    )
    allow(Knowledge::ContainerizedRunner).to receive(:available?).and_return(false)
    scheduled = double(perform_later: true)
    allow(RunCollectorContinuationJob).to receive(:set).with(wait: 1.minute).and_return(scheduled)

    described_class.new.perform(project.id, commit_sha)

    expect(scheduled).to have_received(:perform_later).with(project.id, commit_sha,
      branch: "main", committed_at: nil, collector_index: 0,
      collector_types: [ "tree_sitter" ], preserved_collector_types: [], collector_cursor: "app/a.rb")
  end

  # @spec KNOWLEDGE-014
  it "stops the chain when a collector fails" do
    allow(Knowledge::CollectorRunner).to receive_messages(
      registry: { "first" => Object, "second" => Object },
      call: { results: [ { collector_type: "first", status: "failed" } ] }
    )
    allow(Knowledge::ContainerizedRunner).to receive(:available?).and_return(false)
    allow(RunCollectorContinuationJob).to receive(:perform_later)
    allow(Knowledge::CollectorRunner).to receive(:finalize_collection)

    described_class.new.perform(project.id, commit_sha)

    expect(RunCollectorContinuationJob).not_to have_received(:perform_later)
    expect(Knowledge::CollectorRunner).not_to have_received(:finalize_collection)
    expect(project.reload.knowledge_status).to eq("failed")
  end

  # @spec KNOWLEDGE-014
  it "skips a queued collection after the branch advances" do
    allow(github_client).to receive(:ref)
      .and_return(Struct.new(:object).new(Struct.new(:sha).new("b" * 40)))
    allow(Knowledge::ContainerizedRunner).to receive(:available?)

    described_class.new.perform(project.id, commit_sha)

    expect(Knowledge::ContainerizedRunner).not_to have_received(:available?)
    expect(CollectorRun.count).to eq(0)
  end

  # @spec KNOWLEDGE-014
  it "skips a duplicate start when a continuation is already queued", :good_job do
    original_adapter = RunCollectorContinuationJob.queue_adapter
    RunCollectorContinuationJob.queue_adapter = GoodJob::Adapter.new(execution_mode: :external)
    RunCollectorContinuationJob.perform_later(project.id, commit_sha,
      collector_index: 1, collector_types: %w[first second])
    allow(Knowledge::ContainerizedRunner).to receive(:available?)

    described_class.new.perform(project.id, commit_sha)

    expect(Knowledge::ContainerizedRunner).not_to have_received(:available?)
  ensure
    RunCollectorContinuationJob.queue_adapter = original_adapter
  end

  # @spec KNOWLEDGE-001 KNOWLEDGE-014
  it "keeps the collection status while retrying a database recovery failure" do
    allow(Knowledge::CollectorRunner).to receive(:call)
      .and_raise(ActiveRecord::ConnectionNotEstablished, "database system is in recovery mode")
    allow(Knowledge::ContainerizedRunner).to receive(:available?).and_return(false)
    allow(Knowledge::CollectorRunner).to receive(:registry).and_return({ "first" => Object })

    job = described_class.new(project.id, commit_sha)
    job.exception_executions = { "[ActiveRecord::ConnectionNotEstablished]" => 0 }

    expect { job.perform_now }.not_to raise_error
    expect(project.reload.knowledge_status).to eq("collecting")
  end
end
