# frozen_string_literal: true

require "rails_helper"

RSpec.describe Knowledge::Uri do
  # @spec KNOWLEDGE-URI-001
  describe ".build_artifact" do
    it "builds the active-view grammar" do
      uri = described_class.build_artifact(
        project_id: 42,
        artifact_type: "route",
        scope_path: "config/routes.rb",
        identifier: "GET /api/users"
      )

      expect(uri).to eq("paidkb://project/42/artifact/route/config%2Froutes.rb/GET%20%2Fapi%2Fusers")
    end

    it "encodes a blank scope_path as an empty segment" do
      uri = described_class.build_artifact(
        project_id: 1, artifact_type: "language_stat", scope_path: nil, identifier: "Ruby"
      )

      expect(uri).to eq("paidkb://project/1/artifact/language_stat//Ruby")
    end

    it "inserts a commit segment without changing the active-view grammar otherwise" do
      uri = described_class.build_artifact(
        project_id: 1, artifact_type: "route", scope_path: "config/routes.rb",
        identifier: "GET /x", commit_sha: "abc123"
      )

      expect(uri).to eq("paidkb://project/1/commit/abc123/artifact/route/config%2Froutes.rb/GET%20%2Fx")
    end
  end

  describe ".build_chunk" do
    it "builds a chunk uri from the project id and chunk uuid" do
      uri = described_class.build_chunk(project_id: 7, chunk_id: "11111111-1111-1111-1111-111111111111")

      expect(uri).to eq("paidkb://project/7/chunk/11111111-1111-1111-1111-111111111111")
    end
  end

  describe ".for_artifact and .for_chunk" do
    it "delegates to the record's project_id, artifact_type, scope_path, and identifier" do
      artifact = create(:knowledge_artifact)

      expect(described_class.for_artifact(artifact)).to eq(
        described_class.build_artifact(
          project_id: artifact.project_id, artifact_type: artifact.artifact_type,
          scope_path: artifact.scope_path, identifier: artifact.identifier
        )
      )
    end

    it "delegates to the chunk's project_id and id" do
      chunk = create(:knowledge_chunk)

      expect(described_class.for_chunk(chunk)).to eq(
        described_class.build_chunk(project_id: chunk.project_id, chunk_id: chunk.id)
      )
    end
  end

  describe ".parse" do
    it "round-trips an artifact uri" do
      uri = described_class.build_artifact(
        project_id: 42, artifact_type: "route", scope_path: "config/routes.rb", identifier: "GET /api/users"
      )

      parsed = described_class.parse(uri)

      expect(parsed.kind).to eq(:artifact)
      expect(parsed.project_id).to eq("42")
      expect(parsed.artifact_type).to eq("route")
      expect(parsed.scope_path).to eq("config/routes.rb")
      expect(parsed.identifier).to eq("GET /api/users")
      expect(parsed.commit_sha).to be_nil
    end

    it "round-trips a blank scope_path as an empty segment" do
      uri = described_class.build_artifact(project_id: 1, artifact_type: "language_stat", scope_path: nil, identifier: "Ruby")

      expect(described_class.parse(uri).scope_path).to eq("")
    end

    it "round-trips a blank identifier as an empty segment" do
      uri = described_class.build_artifact(project_id: 1, artifact_type: "language_stat", scope_path: "config/routes.rb", identifier: "")

      expect(described_class.parse(uri).identifier).to eq("")
    end

    it "round-trips an empty string scope_path and identifier together" do
      uri = described_class.build_artifact(project_id: 1, artifact_type: "language_stat", scope_path: "", identifier: "")

      parsed = described_class.parse(uri)

      expect(parsed.scope_path).to eq("")
      expect(parsed.identifier).to eq("")
    end

    it "round-trips a blank identifier on a commit-pinned artifact uri" do
      uri = described_class.build_artifact(
        project_id: 1, artifact_type: "language_stat", scope_path: nil, identifier: "",
        commit_sha: "abc123"
      )

      parsed = described_class.parse(uri)

      expect(parsed.scope_path).to eq("")
      expect(parsed.identifier).to eq("")
      expect(parsed.commit_sha).to eq("abc123")
    end

    it "round-trips a chunk uri" do
      parsed = described_class.parse("paidkb://project/7/chunk/abc-123")

      expect(parsed.kind).to eq(:chunk)
      expect(parsed.project_id).to eq("7")
      expect(parsed.chunk_id).to eq("abc-123")
    end

    it "round-trips a commit-pinned artifact uri" do
      uri = described_class.build_artifact(
        project_id: 1, artifact_type: "route", scope_path: "config/routes.rb", identifier: "GET /x", commit_sha: "abc123"
      )

      parsed = described_class.parse(uri)

      expect(parsed.commit_sha).to eq("abc123")
    end

    it "raises for a non-paidkb scheme" do
      expect { described_class.parse("https://example.com/project/1") }
        .to raise_error(Knowledge::Uri::InvalidUriError)
    end

    it "raises for a blank uri" do
      expect { described_class.parse("") }.to raise_error(Knowledge::Uri::InvalidUriError)
      expect { described_class.parse(nil) }.to raise_error(Knowledge::Uri::InvalidUriError)
    end

    it "raises for a malformed uri missing the project id" do
      expect { described_class.parse("paidkb://project") }.to raise_error(Knowledge::Uri::InvalidUriError)
    end

    it "raises for an unknown resource kind" do
      expect { described_class.parse("paidkb://project/1/unknown/thing") }
        .to raise_error(Knowledge::Uri::InvalidUriError)
    end

    it "raises for an artifact uri with the wrong number of segments" do
      expect { described_class.parse("paidkb://project/1/artifact/route/only-scope") }
        .to raise_error(Knowledge::Uri::InvalidUriError)
    end

    it "raises for a commit segment missing a sha" do
      expect { described_class.parse("paidkb://project/1/commit") }
        .to raise_error(Knowledge::Uri::InvalidUriError)
    end
  end
end
