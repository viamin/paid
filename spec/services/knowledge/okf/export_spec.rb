# frozen_string_literal: true

require "rails_helper"

# @spec KNOWLEDGE-OKF-005
RSpec.describe Knowledge::Okf::Export do
  let(:project) { create(:project) }
  let(:project_version) { create(:project_version, project:, commit_sha: "a" * 40) }
  let(:collector_run) { create(:collector_run, project_version:, collector_type: "okf") }

  def artifact_with_chunks(chunk_types:, artifact_type: "okf_concept", metadata: {}, status: "active",
    identifier: "Auth flows", scope_path: ".okf/concepts/auth.md")
    artifact = create(
      :knowledge_artifact,
      collector_run:,
      project:,
      artifact_type:,
      status:,
      identifier:,
      scope_path:,
      metadata: metadata
    )
    chunk_types.each_with_index do |(type, content, chunk_status), index|
      create(:knowledge_chunk, knowledge_artifact: artifact, project:, chunk_type: type,
        content: content, status: chunk_status || "active", sequence: index)
    end
    artifact
  end

  describe "#call" do
    it "raises when no exportable artifact types are selected" do
      expect { described_class.call(project:, artifact_types: [ "unknown_type" ]) }
        .to raise_error(ArgumentError, /select at least one/)
    end

    it "exports curated artifacts as a single valid OKF file" do
      artifact_with_chunks(chunk_types: [ [ "summary", "Auth summary" ], [ "definition", "Users sign in with SSO." ] ])

      result = described_class.call(project:, artifact_types: [ "okf_concept" ])

      expect(result.files.length).to eq(1)
      file = result.files.first
      expect(file.relative_path).to match(%r{\Aokf_concept/auth-flows-\d+\.md\z})

      parsed = Knowledge::Okf::Frontmatter.parse(file.content)
      expect(parsed).to be_valid
      expect(parsed.body).to eq("Users sign in with SSO.")
    end

    it "carries Paid provenance metadata in the exported frontmatter" do
      artifact_with_chunks(chunk_types: [ [ "definition", "Users sign in with SSO." ] ])

      result = described_class.call(project:, artifact_types: [ "okf_concept" ])
      paid = Knowledge::Okf::Frontmatter.parse(result.files.first.content).frontmatter["paid"]

      expect(paid).to include(
        "artifact_type" => "okf_concept",
        "collector_type" => "okf",
        "scope" => ".okf/concepts/auth.md",
        "identifier" => "Auth flows",
        "commit_sha" => "a" * 40
      )
      expect(paid["kb_uri"]).to be_present
      expect(paid["created_at"]).to be_present
    end

    it "falls back to joining active chunks when no definition chunk exists" do
      artifact_with_chunks(chunk_types: [ [ "summary", "Just a summary line" ] ], artifact_type: "route")

      result = described_class.call(project:, artifact_types: [ "route" ])

      parsed = Knowledge::Okf::Frontmatter.parse(result.files.first.content)
      expect(parsed.body).to eq("Just a summary line")
    end

    it "skips artifacts with no active chunks instead of exporting raw content" do
      artifact_with_chunks(chunk_types: [ [ "definition", "[REDACTED]", "redacted" ] ])

      result = described_class.call(project:, artifact_types: [ "okf_concept" ])

      expect(result.files).to be_empty
      expect(result.skipped_count).to eq(1)
    end

    it "excludes stale artifacts" do
      artifact_with_chunks(chunk_types: [ [ "definition", "Stale body" ] ], status: "stale")

      result = described_class.call(project:, artifact_types: [ "okf_concept" ])

      expect(result.files).to be_empty
    end

    it "ignores artifact types outside the exportable allowlist" do
      artifact_with_chunks(chunk_types: [ [ "definition", "Body" ] ])

      result = described_class.call(project:, artifact_types: [ "okf_concept", "agent_run" ])

      expect(result.artifact_types).to eq([ "okf_concept" ])
    end

    it "records an audit event with export details" do
      artifact_with_chunks(chunk_types: [ [ "definition", "Body" ] ])

      expect {
        described_class.call(project:, artifact_types: [ "okf_concept" ], actor: { type: "user", id: "1" })
      }.to change(KnowledgeAuditEvent, :count).by(1)

      event = KnowledgeAuditEvent.last
      expect(event.event_type).to eq("okf_bundle_exported")
      expect(event.details).to include(
        "artifact_types" => [ "okf_concept" ], "exported_count" => 1, "skipped_count" => 0, "truncated_types" => []
      )
    end

    context "when a selected type exceeds max_artifacts" do
      before do
        3.times do |n|
          artifact_with_chunks(chunk_types: [ [ "definition", "Body #{n}" ] ], artifact_type: "route",
            identifier: "Route #{n}", scope_path: "app/routes_#{n}.rb")
        end
        artifact_with_chunks(chunk_types: [ [ "definition", "Concept body" ] ], artifact_type: "okf_concept")
      end

      it "applies the limit per type instead of starving later types" do
        result = described_class.call(project:, artifact_types: [ "route", "okf_concept" ], max_artifacts: 2)

        route_files = result.files.count { |f| f.relative_path.start_with?("route/") }
        concept_files = result.files.count { |f| f.relative_path.start_with?("okf_concept/") }
        expect(route_files).to eq(2)
        expect(concept_files).to eq(1)
      end

      it "flags the truncated type on the result and includes a notice file in the bundle" do
        result = described_class.call(project:, artifact_types: [ "route", "okf_concept" ], max_artifacts: 2)

        expect(result.truncated_types).to eq([ "route" ])
        notice = result.files.find { |f| f.relative_path == "TRUNCATION_NOTICE.txt" }
        expect(notice).to be_present
        expect(notice.content).to include("route")
      end

      it "records truncated_types in the audit event" do
        described_class.call(project:, artifact_types: [ "route", "okf_concept" ], max_artifacts: 2)

        expect(KnowledgeAuditEvent.last.details).to include("truncated_types" => [ "route" ])
      end

      it "does not truncate when max_artifacts is not exceeded" do
        result = described_class.call(project:, artifact_types: [ "route", "okf_concept" ], max_artifacts: 10)

        expect(result.truncated_types).to eq([])
        expect(result.files.map(&:relative_path)).not_to include("TRUNCATION_NOTICE.txt")
      end
    end
  end
end
