# frozen_string_literal: true

require "rails_helper"
require "rake"

# rubocop:disable RSpec/DescribeClass
RSpec.describe "knowledge:redact" do
  before do
    Rails.application.load_tasks unless Rake::Task.task_defined?("knowledge:redact:scrub")
    Rake::Task["knowledge:redact:scrub"].reenable
    Rake::Task["knowledge:redact:reembed"].reenable

    # Default env values used by both tasks.
    ENV["DRY_RUN"] = nil
    ENV["SINCE"] = nil
    ENV["ACTOR_ID"] = nil
    ENV["CHUNK_IDS"] = nil
    ENV["SKIP_REEMBED"] = nil
  end

  after do
    ENV["DRY_RUN"] = nil
    ENV["SINCE"] = nil
    ENV["ACTOR_ID"] = nil
    ENV["CHUNK_IDS"] = nil
    ENV["SKIP_REEMBED"] = nil
  end

  describe "knowledge:redact:scrub" do
    let(:scrubber) { instance_double(Knowledge::Redaction::Scrubber) }
    let(:project) { create(:project) }
    let(:result) do
      Knowledge::Redaction::Scrubber::Result.new(
        scanned_chunks: 5,
        scrubbed_chunks: 3,
        skipped_chunks: 0,
        deleted_qdrant_points: 3,
        qdrant_collection_rebuilt: false,
        duration_seconds: 0.5
      )
    end

    before do
      allow(Knowledge::Redaction::Scrubber).to receive(:new).and_return(scrubber)
      allow(scrubber).to receive(:call).and_return(result)
    end

    it "requires a project id" do
      expect {
        Rake::Task["knowledge:redact:scrub"].invoke
      }.to raise_error(SystemExit)
        .and output(/PROJECT_ID is required/).to_stderr
    end

    it "aborts when the project is not found" do
      expect {
        Rake::Task["knowledge:redact:scrub"].invoke(0)
      }.to raise_error(SystemExit)
        .and output(/Project 0 not found/).to_stderr
    end

    it "invokes the scrubber with the project's qdrant_client and prints a summary" do
      ENV["ACTOR_ID"] = "99"

      expect(Knowledge::Redaction::Scrubber).to receive(:new).with(
        project: project,
        qdrant_client: Paid.qdrant_client,
        actor: { type: "operator", id: "99" },
        dry_run: false
      ).and_return(scrubber)

      expect { Rake::Task["knowledge:redact:scrub"].invoke(project.id.to_s) }
        .to output(/Scrubbed 3 chunk/).to_stdout
    end

    it "passes dry_run: true when DRY_RUN=true" do
      ENV["DRY_RUN"] = "true"

      expect(Knowledge::Redaction::Scrubber).to receive(:new).with(
        hash_including(dry_run: true)
      ).and_return(scrubber)

      Rake::Task["knowledge:redact:scrub"].invoke(project.id.to_s)
    end

    it "queues EmbedChunksJob when not dry-run and chunks were scrubbed" do
      allow(EmbedChunksJob).to receive(:perform_later)

      Rake::Task["knowledge:redact:scrub"].invoke(project.id.to_s)

      expect(EmbedChunksJob).to have_received(:perform_later).with(project.id)
    end

    it "does not enqueue re-embed when SKIP_REEMBED=true" do
      ENV["SKIP_REEMBED"] = "true"
      allow(EmbedChunksJob).to receive(:perform_later)

      Rake::Task["knowledge:redact:scrub"].invoke(project.id.to_s)

      expect(EmbedChunksJob).not_to have_received(:perform_later)
    end

    it "does not enqueue re-embed when no chunks were scrubbed" do
      empty_result = Knowledge::Redaction::Scrubber::Result.new(
        scanned_chunks: 0,
        scrubbed_chunks: 0,
        skipped_chunks: 0,
        deleted_qdrant_points: 0,
        qdrant_collection_rebuilt: false,
        duration_seconds: 0.1
      )
      allow(scrubber).to receive(:call).and_return(empty_result)
      allow(EmbedChunksJob).to receive(:perform_later)

      Rake::Task["knowledge:redact:scrub"].invoke(project.id.to_s)

      expect(EmbedChunksJob).not_to have_received(:perform_later)
    end
  end

  describe "knowledge:redact:reembed" do
    let(:project) { create(:project) }
    let(:reembed) { instance_double(Knowledge::Redaction::Reembed) }
    let(:result) do
      Knowledge::Redaction::Reembed::Result.new(
        reembedded_count: 4,
        skipped_count: 0,
        duration_seconds: 0.25
      )
    end
    let(:provider_configs) { [ Knowledge::RunnerConfiguration::Result.new(runner: "openai") ] }
    let(:proxy_generator) do
      instance_double(
        Knowledge::Embeddings::ProxyGenerator,
        model: "text-embedding-3-large"
      )
    end

    before do
      allow(Knowledge::RunnerConfiguration).to receive(:for_embedding_candidate_runners)
        .with(project: project)
        .and_return(provider_configs)
      allow(Knowledge::Embeddings::ProxyGenerator).to receive(:new).and_return(proxy_generator)
      allow(Knowledge::Redaction::Reembed).to receive(:new).and_return(reembed)
      allow(reembed).to receive(:call).and_return(result)
    end

    it "requires a project id" do
      expect {
        Rake::Task["knowledge:redact:reembed"].invoke
      }.to raise_error(SystemExit)
        .and output(/PROJECT_ID is required/).to_stderr
    end

    it "aborts when the project is not found" do
      expect {
        Rake::Task["knowledge:redact:reembed"].invoke(0)
      }.to raise_error(SystemExit)
        .and output(/Project 0 not found/).to_stderr
    end

    it "invokes Reembed with a ProxyGenerator and prints a summary" do
      expect(Knowledge::Embeddings::ProxyGenerator).to receive(:new).with(
        project: project,
        provider_configs: provider_configs,
        containerize: true
      ).and_return(proxy_generator)

      expect(Knowledge::Redaction::Reembed).to receive(:new).with(
        project: project,
        generator: proxy_generator,
        actor: hash_including(type: "operator"),
        since: nil,
        chunk_ids: nil
      ).and_return(reembed)

      expect { Rake::Task["knowledge:redact:reembed"].invoke(project.id.to_s) }
        .to output(/Re-embedded 4 chunk/).to_stdout
    end

    it "aborts when SINCE is not parseable" do
      ENV["SINCE"] = "not a timestamp"

      expect {
        Rake::Task["knowledge:redact:reembed"].invoke(project.id.to_s)
      }.to raise_error(SystemExit)
        .and output(/Invalid SINCE/).to_stderr
    end

    it "passes a parsed SINCE timestamp to Reembed" do
      ENV["SINCE"] = "2026-05-01T00:00:00Z"
      parsed_since = Time.parse("2026-05-01T00:00:00Z")

      expect(Knowledge::Redaction::Reembed).to receive(:new).with(
        hash_including(since: parsed_since)
      ).and_return(reembed)

      Rake::Task["knowledge:redact:reembed"].invoke(project.id.to_s)
    end

    it "passes an explicit CHUNK_IDS list to Reembed" do
      ENV["CHUNK_IDS"] = "abc-123, def-456"

      expect(Knowledge::Redaction::Reembed).to receive(:new).with(
        hash_including(chunk_ids: [ "abc-123", "def-456" ])
      ).and_return(reembed)

      Rake::Task["knowledge:redact:reembed"].invoke(project.id.to_s)
    end
  end
end
# rubocop:enable RSpec/DescribeClass
