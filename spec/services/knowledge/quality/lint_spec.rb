# frozen_string_literal: true

require "rails_helper"

# @spec KNOWLEDGE-LINT-001
RSpec.describe Knowledge::Quality::Lint do
  let(:account) { create(:account) }
  let(:project) { create(:project, account: account) }

  around do |example|
    original_registry = Knowledge::CollectorRunner.registry.dup
    Knowledge::CollectorRunner.reset_registry!
    Knowledge::CollectorRunner.register("routes", Knowledge::Collectors::RoutesCollector)
    Knowledge::CollectorRunner.register("schema", Knowledge::Collectors::SchemaCollector)
    example.run
  ensure
    Knowledge::CollectorRunner.reset_registry!
    original_registry.each { |type, klass| Knowledge::CollectorRunner.register(type, klass) }
  end

  def drop_knowledge_chunks_artifact_fk
    connection = KnowledgeChunk.connection
    fk_name = connection.execute(
      "SELECT conname FROM pg_constraint WHERE conrelid = 'knowledge_chunks'::regclass " \
      "AND contype = 'f' AND pg_get_constraintdef(oid) LIKE '%knowledge_artifacts%'"
    ).first&.dig("conname")
    connection.execute("ALTER TABLE knowledge_chunks DROP CONSTRAINT #{fk_name}") if fk_name
    fk_name
  end

  def restore_knowledge_chunks_artifact_fk(fk_name)
    return unless fk_name

    KnowledgeChunk.connection.execute(
      "ALTER TABLE knowledge_chunks ADD CONSTRAINT #{fk_name} FOREIGN KEY (knowledge_artifact_id) " \
      "REFERENCES knowledge_artifacts(id) ON DELETE CASCADE NOT VALID"
    )
  end

  describe ".call" do
    it "returns a bounded, structured report for an empty project" do
      report = described_class.call(project: project)

      expect(report[:project_id]).to eq(project.id)
      expect(report[:generated_at]).to be_present
      expect(report[:summary][:total]).to eq(report[:findings].size)
      expect(report[:checks]).to include("stale_scope_path", "dangling_link", "low_usage_type")
      # A fresh project still surfaces never-run collectors as findings.
      expect(report[:findings].map { |f| f[:code] }).to include("never_run_collector")
    end

    it "exposes the stable check registry" do
      codes = described_class.check_codes
      expect(codes).to include(
        "stale_scope_path",
        "stale_commit_reference",
        "orphaned_artifact",
        "orphaned_chunk",
        "dangling_link",
        "empty_artifact",
        "fully_redacted_artifact",
        "chunk_missing_embedding",
        "chunk_missing_redaction_scan",
        "low_usage_type",
        "stale_collector",
        "never_run_collector",
        "failed_collector"
      )
    end

    it "flags artifacts whose scope_path no longer exists in HEAD as stale" do
      project_version = create(:project_version, project: project, commit_sha: "a" * 40)
      collector_run = create(:collector_run, :completed, project_version: project_version, collector_type: "routes")
      create(:knowledge_artifact, project: project, collector_run: collector_run,
        artifact_type: "route", scope_path: "app/controllers/missing_controller.rb", status: "active")

      check = Knowledge::Quality::Checks::StaleScopePath.new(project: project)
      allow(check).to receive(:tracked_files).and_return(Set["config/routes.rb"])
      allow(check).to receive(:file_exists?) do |scope_path|
        scope_path != "app/controllers/missing_controller.rb"
      end
      allow(Knowledge::Quality::Checks::StaleScopePath).to receive(:new).and_return(check)

      report = described_class.call(project: project)

      finding = report[:findings].find { |f| f[:code] == "stale_scope_path" }
      expect(finding).to be_present
      expect(finding[:severity]).to eq("warning")
      expect(finding[:target_type]).to eq("KnowledgeArtifact")
    end

    it "flags an artifact whose collector commit SHA no longer matches HEAD as stale_commit_reference" do
      old_version = create(:project_version, project: project, commit_sha: "a" * 40, committed_at: 2.days.ago)
      latest_version = create(:project_version, project: project, commit_sha: "b" * 40, committed_at: 1.hour.ago)
      collector_run = create(:collector_run, :completed, project_version: old_version, collector_type: "routes")
      create(:knowledge_artifact, project: project, collector_run: collector_run,
        artifact_type: "route", status: "active")

      report = described_class.call(project: project)

      finding = report[:findings].find { |f| f[:code] == "stale_commit_reference" }
      expect(finding).to be_present
      expect(finding[:severity]).to eq("info")
      expect(finding[:detail]).to include(old_version.commit_sha.first(7))
      expect(finding[:detail]).to include(latest_version.commit_sha.first(7))
    end

    it "flags active artifacts with zero chunks as orphaned_artifact" do
      project_version = create(:project_version, project: project)
      collector_run = create(:collector_run, :completed, project_version: project_version, collector_type: "routes")
      create(:knowledge_artifact, project: project, collector_run: collector_run,
        artifact_type: "route", status: "active")

      report = described_class.call(project: project)

      finding = report[:findings].find { |f| f[:code] == "orphaned_artifact" }
      expect(finding).to be_present
      expect(finding[:severity]).to eq("warning")
    end

    it "flags active chunks whose artifact is missing as orphaned_chunk" do
      project_version = create(:project_version, project: project)
      collector_run = create(:collector_run, :completed, project_version: project_version, collector_type: "routes")
      artifact = create(:knowledge_artifact, project: project, collector_run: collector_run,
        artifact_type: "route", status: "active")
      chunk = create(:knowledge_chunk, knowledge_artifact: artifact, project: project, status: "active")

      # Bypass the cascade FK by temporarily dropping it so we can simulate a
      # true orphan (a chunk whose parent artifact row has been removed but
      # the chunk itself remains). The lint check is meant to catch exactly
      # this data-integrity surprise.
      fk_name = drop_knowledge_chunks_artifact_fk
      KnowledgeArtifact.where(id: artifact.id).delete_all
      report = described_class.call(project: project)
      restore_knowledge_chunks_artifact_fk(fk_name)

      finding = report[:findings].find { |f| f[:code] == "orphaned_chunk" && f[:target_id] == chunk.id.to_s }
      expect(finding).to be_present
      expect(finding[:severity]).to eq("error")
    end

    it "flags links whose endpoints no longer exist as dangling_link" do
      project_version = create(:project_version, project: project)
      collector_run = create(:collector_run, :completed, project_version: project_version, collector_type: "routes")
      source_artifact = create(:knowledge_artifact, project: project, collector_run: collector_run,
        artifact_type: "route", status: "active")
      source_chunk = create(:knowledge_chunk, knowledge_artifact: source_artifact, project: project, status: "active")
      target_artifact = create(:knowledge_artifact, project: project, collector_run: collector_run,
        artifact_type: "route", status: "active")
      target_chunk = create(:knowledge_chunk, knowledge_artifact: target_artifact, project: project, status: "active")
      link = create(:knowledge_link, source_chunk: source_chunk, target_chunk: target_chunk)
      target_chunk.update_columns(status: "deleted")

      report = described_class.call(project: project)

      finding = report[:findings].find { |f| f[:code] == "dangling_link" && f[:target_id] == link.id.to_s }
      expect(finding).to be_present
      expect(finding[:severity]).to eq("warning")
      expect(finding[:detail]).to include(link.link_type)
    end

    it "flags active chunks without embeddings on active artifacts as chunk_missing_embedding" do
      project_version = create(:project_version, project: project)
      collector_run = create(:collector_run, :completed, project_version: project_version, collector_type: "routes")
      artifact = create(:knowledge_artifact, project: project, collector_run: collector_run,
        artifact_type: "route", status: "active")
      create(:knowledge_chunk, knowledge_artifact: artifact, project: project,
        status: "active", embedding_model: nil)

      report = described_class.call(project: project)

      finding = report[:findings].find { |f| f[:code] == "chunk_missing_embedding" }
      expect(finding).to be_present
      expect(finding[:severity]).to eq("warning")
    end

    it "flags active chunks without a redaction scan as chunk_missing_redaction_scan" do
      project_version = create(:project_version, project: project)
      collector_run = create(:collector_run, :completed, project_version: project_version, collector_type: "routes")
      artifact = create(:knowledge_artifact, project: project, collector_run: collector_run,
        artifact_type: "route", status: "active")
      create(:knowledge_chunk, knowledge_artifact: artifact, project: project,
        status: "active", redaction_scanned_at: nil)

      report = described_class.call(project: project)

      finding = report[:findings].find { |f| f[:code] == "chunk_missing_redaction_scan" }
      expect(finding).to be_present
      expect(finding[:severity]).to eq("info")
    end

    it "flags artifact types with low or zero retrieval usage as low_usage_type" do
      run = create(:agent_run, :completed, project: project)
      create(:knowledge_usage_stat, agent_run: run, project: project,
        artifact_type: "route", artifact_count: 100)
      project_version = create(:project_version, project: project)
      collector_run = create(:collector_run, :completed, project_version: project_version, collector_type: "schema")
      create(:knowledge_artifact, project: project, collector_run: collector_run,
        artifact_type: "schema", status: "active")

      report = described_class.call(project: project)

      finding = report[:findings].find { |f| f[:code] == "low_usage_type" }
      expect(finding).to be_present
      expect(finding[:severity]).to eq("info")
    end

    it "flags a never-run collector as never_run_collector" do
      report = described_class.call(project: project)

      expect(report[:findings].map { |f| f[:code] }).to include("never_run_collector")
    end

    it "flags a failed collector as failed_collector with the error detail" do
      project_version = create(:project_version, project: project)
      create(:collector_run, :failed, project_version: project_version, collector_type: "schema",
        error_message: "explosion")

      report = described_class.call(project: project)

      finding = report[:findings].find { |f| f[:code] == "failed_collector" }
      expect(finding).to be_present
      expect(finding[:detail]).to include("explosion")
      expect(finding[:severity]).to eq("error")
    end

    it "flags a collector whose latest run predates the latest indexed commit as stale_collector" do
      older_version = create(:project_version, project: project, committed_at: 2.days.ago)
      newer_version = create(:project_version, project: project, committed_at: 1.hour.ago)
      create(:collector_run, :completed, project_version: older_version, collector_type: "schema")
      create(:collector_run, :completed, project_version: newer_version, collector_type: "routes")

      report = described_class.call(project: project)

      expect(report[:findings].map { |f| f[:code] }).to include("stale_collector")
    end

    it "flags an artifact whose chunks are all redacted or deleted as fully_redacted_artifact" do
      project_version = create(:project_version, project: project)
      collector_run = create(:collector_run, :completed, project_version: project_version, collector_type: "okf")
      artifact = create(:knowledge_artifact, project: project, collector_run: collector_run,
        artifact_type: "okf_concept", status: "active")
      create(:knowledge_chunk, knowledge_artifact: artifact, project: project,
        status: "redacted")

      report = described_class.call(project: project)

      finding = report[:findings].find { |f| f[:code] == "fully_redacted_artifact" }
      expect(finding).to be_present
      expect(finding[:severity]).to eq("warning")
    end

    it "does not mutate any knowledge state" do
      project_version = create(:project_version, project: project)
      collector_run = create(:collector_run, :completed, project_version: project_version, collector_type: "routes")
      artifact = create(:knowledge_artifact, project: project, collector_run: collector_run,
        artifact_type: "route", status: "active")
      chunk = create(:knowledge_chunk, knowledge_artifact: artifact, project: project, status: "active")
      snapshot = lambda do
        {
          artifact_status: artifact.reload.status,
          artifact_collector_type: artifact.reload.collector_type,
          chunk_status: chunk.reload.status,
          chunk_content: chunk.reload.content,
          chunks_count: KnowledgeChunk.where(knowledge_artifact_id: artifact.id).count
        }
      end

      before = snapshot.call
      described_class.call(project: project)
      after = snapshot.call

      expect(after).to eq(before)
    end

    it "caps a check's findings at MAX_FINDINGS_PER_CHECK and reports the omitted count" do
      project_version = create(:project_version, project: project)
      collector_run = create(:collector_run, :completed, project_version: project_version, collector_type: "routes")
      finding_count = described_class::MAX_FINDINGS_PER_CHECK + 3
      finding_count.times do
        create(:knowledge_artifact, project: project, collector_run: collector_run,
          artifact_type: "route", status: "active")
      end

      report = described_class.call(project: project)

      orphaned = report[:findings].select { |f| f[:code] == "orphaned_artifact" }
      expect(orphaned.size).to eq(described_class::MAX_FINDINGS_PER_CHECK)
      expect(report[:truncated_checks]).to include(code: "orphaned_artifact", omitted_count: 3)
      expect(report[:summary][:total]).to eq(report[:findings].size)
    end

    it "bounds AR instantiation to MAX_FINDINGS_PER_CHECK when a check overflows the cap" do
      # KNOWLEDGE-LINT-001 promises a bounded report on large projects — the
      # bound has to cover work, not just payload. If a check materialized
      # every matching row before deciding what to store, tens of thousands
      # of matches would blow up memory / DB round-trips on the sync request
      # path.
      project_version = create(:project_version, project: project)
      collector_run = create(:collector_run, :completed, project_version: project_version, collector_type: "routes")
      finding_count = described_class::MAX_FINDINGS_PER_CHECK + 5
      finding_count.times do
        create(:knowledge_artifact, project: project, collector_run: collector_run,
          artifact_type: "route", status: "active")
      end

      instantiations = 0
      original_new = KnowledgeArtifact.method(:instantiate)
      allow(KnowledgeArtifact).to receive(:instantiate).and_wrap_original do |m, *args, **kwargs|
        instantiations += 1
        original_new.call(*args, **kwargs)
      end

      described_class.call(project: project)

      # Bound is per-check; several checks may load rows, but each capped
      # check should load at most MAX_FINDINGS_PER_CHECK from KnowledgeArtifact.
      # OrphanedArtifact runs two capped queries against this table (zero-chunk
      # and all-deleted-chunk paths), so a modest multiple of the cap is
      # acceptable; the pre-fix behavior would have loaded ~finding_count rows
      # for orphaned alone and again for stale_commit_reference.
      expect(instantiations).to be < finding_count
    end

    it "reports no truncated checks when every check stays within the cap" do
      report = described_class.call(project: project)

      expect(report[:truncated_checks]).to eq([])
    end

    it "summarizes findings by severity" do
      project_version = create(:project_version, project: project)
      create(:collector_run, :failed, project_version: project_version, collector_type: "schema",
        error_message: "boom")

      report = described_class.call(project: project)

      expect(report[:summary][:error]).to be >= 1
      expect(report[:summary][:warning]).to be >= 0
      expect(report[:summary][:info]).to be >= 0
      expect(report[:summary][:total]).to eq(report[:findings].size)
    end
  end
end
