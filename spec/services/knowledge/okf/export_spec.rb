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

    it "excludes artifacts with no active chunks from the export instead of exporting raw content" do
      artifact_with_chunks(chunk_types: [ [ "definition", "[REDACTED]", "redacted" ] ])

      result = described_class.call(project:, artifact_types: [ "okf_concept" ])

      expect(result.files).to be_empty
      expect(result.skipped_count).to eq(0)
    end

    it "does not let a fully redacted artifact that sorts first starve the per-type limit" do
      artifact_with_chunks(chunk_types: [ [ "definition", "[REDACTED]", "redacted" ] ], identifier: "AAA redacted")
      exportable = artifact_with_chunks(chunk_types: [ [ "definition", "Users sign in with SSO." ] ],
        identifier: "BBB exportable")

      result = described_class.call(project:, artifact_types: [ "okf_concept" ], max_artifacts: 1)

      expect(result.exported_count).to eq(1)
      expect(result.files.map(&:relative_path)).to contain_exactly("okf_concept/bbb-exportable-#{exportable.id}.md")
      expect(result.truncated_types).to be_empty
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

    it "reports exported_count separately from files, which also carries the truncation notice" do
      artifact_with_chunks(chunk_types: [ [ "definition", "Body" ] ])

      result = described_class.call(project:, artifact_types: [ "okf_concept" ])

      expect(result.exported_count).to eq(1)
      expect(result.files.length).to eq(1)
    end

    it "bounds the file slug so a long title cannot overflow the tar entry name limit" do
      artifact_with_chunks(
        chunk_types: [ [ "definition", "Body" ] ],
        artifact_type: "reference_document",
        identifier: "a" * 300
      )

      result = described_class.call(project:, artifact_types: [ "reference_document" ])

      relative_path = result.files.first.relative_path
      basename = relative_path.split("/").last
      expect(basename.bytesize).to be <= 100
      expect(Knowledge::Okf::Frontmatter.parse(result.files.first.content)).to be_valid
    end

    context "when the aggregate artifact ceiling is reached" do
      before do
        3.times do |n|
          artifact_with_chunks(chunk_types: [ [ "definition", "Body #{n}" ] ], artifact_type: "route",
            identifier: "Route #{n}", scope_path: "app/routes_#{n}.rb")
        end
        artifact_with_chunks(chunk_types: [ [ "definition", "Concept body" ] ], artifact_type: "okf_concept")
      end

      it "stops appending once max_total_artifacts is hit and flags the remaining types as truncated" do
        result = described_class.call(project:, artifact_types: [ "route", "okf_concept" ],
          max_artifacts: 10, max_total_artifacts: 2)

        route_files = result.files.count { |f| f.relative_path.start_with?("route/") }
        concept_files = result.files.count { |f| f.relative_path.start_with?("okf_concept/") }
        expect(route_files).to eq(2)
        expect(concept_files).to eq(0)
        expect(result.truncated_types).to eq([ "route", "okf_concept" ])
      end

      it "does not exceed max_total_artifacts across all types combined" do
        result = described_class.call(project:, artifact_types: [ "route", "okf_concept" ],
          max_artifacts: 10, max_total_artifacts: 2)

        expect(result.exported_count).to eq(2)
      end
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

      it "does not truncate when max_artifacts is not exceeded" do
        result = described_class.call(project:, artifact_types: [ "route", "okf_concept" ], max_artifacts: 10)

        expect(result.truncated_types).to eq([])
        expect(result.files.map(&:relative_path)).not_to include("TRUNCATION_NOTICE.txt")
      end
    end
  end
end
