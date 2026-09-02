# frozen_string_literal: true

require "rails_helper"

# @spec KNOWLEDGE-009
RSpec.describe Knowledge::Map::Build do
  let(:project) { create(:project) }

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

  describe ".call" do
    it "returns a bounded overview with no data indexed" do
      result = described_class.call(project: project)

      expect(result[:project_id]).to eq(project.id)
      expect(result[:latest_commit]).to be_nil
      expect(result[:artifact_counts]).to eq({})
      expect(result[:lane_counts]).to eq(curated: { active: 0, stale: 0 }, derived: { active: 0, stale: 0 })
      expect(result[:top_scopes]).to eq([])
      expect(result[:business_context]).to eq(present: false, artifact_count: 0, last_synthesized_at: nil)
      expect(result[:imported_documents]).to eq(count: 0, items: [])
    end

    it "reports the most recently committed project version" do
      create(:project_version, project: project, commit_sha: "a" * 40, committed_at: 2.days.ago)
      newest = create(:project_version, project: project, commit_sha: "b" * 40, committed_at: 1.hour.ago)

      result = described_class.call(project: project)

      expect(result[:latest_commit]).to eq(
        commit_sha: newest.commit_sha, branch: newest.branch, committed_at: newest.committed_at.iso8601
      )
    end

    it "counts active and stale artifacts by type" do
      project_version = create(:project_version, project: project)
      collector_run = create(:collector_run, :completed, project_version: project_version, collector_type: "routes")
      create(:knowledge_artifact, project: project, collector_run: collector_run, artifact_type: "route", status: "active")
      create(:knowledge_artifact, project: project, collector_run: collector_run, artifact_type: "route", status: "active")
      create(:knowledge_artifact, project: project, collector_run: collector_run, artifact_type: "route", status: "stale")

      result = described_class.call(project: project)

      expect(result[:artifact_counts]).to eq("route" => { active: 2, stale: 1 })
    end

    # @spec KNOWLEDGE-CURATED-006
    it "buckets active and stale artifact counts by curated/derived lane" do
      project_version = create(:project_version, project: project)
      collector_run = create(:collector_run, :completed, project_version: project_version, collector_type: "routes")
      create(:knowledge_artifact, project: project, collector_run: collector_run, artifact_type: "route", status: "active")
      create(:knowledge_artifact, project: project, collector_run: collector_run, artifact_type: "route", status: "stale")
      create(:knowledge_artifact, project: project, collector_run: collector_run, artifact_type: "decision_record", status: "active")

      result = described_class.call(project: project)

      expect(result[:lane_counts]).to eq(
        curated: { active: 1, stale: 0 },
        derived: { active: 1, stale: 1 }
      )
    end

    it "buckets active artifacts by their top-level scope directory" do
      project_version = create(:project_version, project: project)
      collector_run = create(:collector_run, :completed, project_version: project_version, collector_type: "routes")
      create(:knowledge_artifact, project: project, collector_run: collector_run, scope_path: "app/models/user.rb")
      create(:knowledge_artifact, project: project, collector_run: collector_run, scope_path: "app/models/post.rb")
      create(:knowledge_artifact, project: project, collector_run: collector_run, scope_path: "config/routes.rb")

      result = described_class.call(project: project)

      expect(result[:top_scopes]).to eq(
        [ { scope: "app", artifact_count: 2 }, { scope: "config", artifact_count: 1 } ]
      )
    end

    it "reports freshness for every known collector, including ones that never ran" do
      project_version = create(:project_version, project: project)
      create(:collector_run, :completed, project_version: project_version, collector_type: "routes", artifacts_count: 4)

      result = described_class.call(project: project)
      by_type = result[:collectors].index_by { |c| c[:collector_type] }

      expect(by_type["routes"]).to include(status: "completed", artifacts_count: 4)
      expect(by_type["schema"]).to include(status: "never_run", artifacts_count: nil)
    end

    it "flags a collector that never ran as a gap" do
      result = described_class.call(project: project)

      expect(result[:gaps]).to include(collector_type: "schema", reason: "never_run")
    end

    it "flags a collector whose latest run failed as a gap" do
      project_version = create(:project_version, project: project)
      create(:collector_run, :failed, project_version: project_version, collector_type: "schema", error_message: "boom")
      create(:collector_run, :completed, project_version: project_version, collector_type: "routes")

      result = described_class.call(project: project)

      expect(result[:gaps]).to include(collector_type: "schema", reason: "failed", detail: "boom")
    end

    it "flags a collector whose latest completed run predates the newest indexed commit as stale" do
      older_version = create(:project_version, project: project, committed_at: 2.days.ago)
      newer_version = create(:project_version, project: project, committed_at: 1.hour.ago)
      create(:collector_run, :completed, project_version: older_version, collector_type: "schema")
      create(:collector_run, :completed, project_version: newer_version, collector_type: "routes")

      result = described_class.call(project: project)

      gap = result[:gaps].find { |g| g[:collector_type] == "schema" }
      expect(gap[:reason]).to eq("stale")
    end

    it "does not flag a collector as a gap when its latest run is current" do
      version = create(:project_version, project: project, committed_at: 1.hour.ago)
      create(:collector_run, :completed, project_version: version, collector_type: "routes")
      create(:collector_run, :completed, project_version: version, collector_type: "schema")

      result = described_class.call(project: project)

      expect(result[:gaps]).to be_empty
    end

    it "reports business context presence from synthesized artifacts" do
      project_version = create(:project_version, project: project)
      collector_run = create(:collector_run, :completed, project_version: project_version, collector_type: "context_intake")
      create(:knowledge_artifact, project: project, collector_run: collector_run, artifact_type: "business_context")

      result = described_class.call(project: project)

      expect(result[:business_context]).to include(present: true, artifact_count: 1)
      expect(result[:business_context][:last_synthesized_at]).to eq(collector_run.completed_at.iso8601)
    end

    it "summarizes imported documents without dumping chunk bodies" do
      project_version = create(:project_version, project: project)
      collector_run = create(:collector_run, :completed, project_version: project_version, collector_type: "pdf_import")
      artifact = create(:knowledge_artifact,
        project: project, collector_run: collector_run, artifact_type: "reference_document",
        identifier: "Modern CSS", metadata: { "title" => "Modern CSS Guide" })
      create(:knowledge_chunk, knowledge_artifact: artifact, project: project, content: "sensitive chunk body")

      result = described_class.call(project: project)

      expect(result[:imported_documents][:count]).to eq(1)
      expect(result[:imported_documents][:items]).to eq(
        [ { identifier: "Modern CSS", title: "Modern CSS Guide", imported_at: artifact.created_at.iso8601 } ]
      )
      expect(result.to_s).not_to include("sensitive chunk body")
    end
  end
end
