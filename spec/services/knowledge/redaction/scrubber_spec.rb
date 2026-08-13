# frozen_string_literal: true

require "rails_helper"

# @spec KNOWLEDGE-006
RSpec.describe Knowledge::Redaction::Scrubber do
  let(:project) { create(:project) }
  let(:project_version) { create(:project_version, project: project) }
  let(:collector_run) { create(:collector_run, project_version: project_version) }
  let(:artifact) { create(:knowledge_artifact, collector_run: collector_run, project: project) }
  let(:qdrant_client) { instance_double(QdrantClient) }
  let(:points) { instance_double(Qdrant::Points) }
  let(:collections) { instance_double(Qdrant::Collections) }
  let(:scrubber) do
    described_class.new(
      project: project,
      qdrant_client: qdrant_client,
      actor: { type: "operator", id: "42" }
    )
  end

  before do
    allow(qdrant_client).to receive_messages(points: points, collections: collections)
    allow(points).to receive_messages(
      delete: { "result" => { "status" => "completed" } },
      set_payload: { "result" => true }
    )
    allow(collections).to receive_messages(
      delete: { "result" => true },
      get: { "result" => { "status" => "green" } },
      create: { "result" => true },
      create_index: { "result" => true }
    )
  end

  def build_chunk(content:, scope_path: "app/controllers/users_controller.rb",
    knowledge_artifact_param: nil, status: "active", embedding_model: "text-embedding-3-large")
    art = knowledge_artifact_param || create(
      :knowledge_artifact,
      collector_run: collector_run,
      project: project,
      scope_path: scope_path
    )
    create(:knowledge_chunk, knowledge_artifact: art, project: project, status: status,
      embedding_model: embedding_model, content: content)
  end

  describe ".call" do
    it "physically scrubs content that matches a redaction pattern" do
      chunk = build_chunk(content: "GITHUB_TOKEN=ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijkl")

      scrubber.call

      chunk.reload
      expect(chunk.content).to include("[REDACTED:github_token]")
      expect(chunk.content).not_to include("ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijkl")
      expect(chunk.status).to eq("redacted")
      expect(chunk.content_hash).to eq(Digest::SHA256.hexdigest(chunk.content))
    end

    it "deletes the corresponding Qdrant points" do
      build_chunk(content: "GITHUB_TOKEN=ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijkl")

      scrubber.call

      expect(points).to have_received(:delete).at_least(:once)
    end

    it "marks partial redactions as still active" do
      chunk = build_chunk(content: "User bob@example.com signed in via SSO.")

      scrubber.call

      chunk.reload
      expect(chunk.content).to include("[REDACTED:email]")
      expect(chunk.content).not_to include("bob@example.com")
      expect(chunk.status).to eq("active")
    end

    it "leaves clean chunks untouched" do
      chunk = build_chunk(content: "def hello; puts 'world'; end")
      original_content = chunk.content

      scrubber.call

      expect(chunk.reload.content).to eq(original_content)
    end

    it "emits a chunks_scrubbed summary audit event" do
      build_chunk(content: "GITHUB_TOKEN=ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijkl")

      expect {
        scrubber.call
      }.to change { KnowledgeAuditEvent.by_event_type("chunks_scrubbed").count }.by(1)

      summary = KnowledgeAuditEvent.by_event_type("chunks_scrubbed").last
      expect(summary.actor_type).to eq("operator")
      expect(summary.actor_id).to eq("42")
      expect(summary.details).to include(
        "scope" => "project",
        "dry_run" => false
      )
      expect(summary.details["scrubbed_count"]).to be >= 1
    end

    it "emits a chunk_redacted event per scrubbed chunk" do
      build_chunk(content: "GITHUB_TOKEN=ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijkl")
      build_chunk(content: "User bob@example.com signed in via SSO.")

      expect {
        scrubber.call
      }.to change { KnowledgeAuditEvent.by_event_type("chunk_redacted").count }.by(2)
    end

    it "returns a Result with counts" do
      build_chunk(content: "GITHUB_TOKEN=ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijkl")
      build_chunk(content: "User bob@example.com signed in via SSO.")
      build_chunk(content: "def hello; puts 'world'; end")

      result = scrubber.call

      expect(result).to be_a(described_class::Result)
      expect(result.scanned_chunks).to be >= 2
      expect(result.scrubbed_chunks).to be >= 2
      expect(result.skipped_chunks).to eq(0)
      expect(result.duration_seconds).to be > 0
    end

    it "scopes the scrub by knowledge_artifact_id when scope_filter is provided" do
      in_scope = build_chunk(content: "GITHUB_TOKEN=ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijkl")
      other_artifact = create(:knowledge_artifact, collector_run: collector_run, project: project,
        scope_path: "config/other.yml")
      out_of_scope = build_chunk(
        content: "AKIAIOSFODNN7EXAMPLE",
        knowledge_artifact_param: other_artifact
      )

      scoped = described_class.new(
        project: project,
        qdrant_client: qdrant_client,
        actor: { type: "operator", id: "42" },
        scope_filter: { knowledge_artifact_id: in_scope.knowledge_artifact_id }
      )

      scoped.call

      expect(in_scope.reload.status).to eq("redacted")
      expect(out_of_scope.reload.status).to eq("active")
    end

    it "scopes the scrub by scope_path when scope_filter is provided" do
      secret_artifact = create(:knowledge_artifact, collector_run: collector_run, project: project,
        scope_path: "config/secrets.yml")
      other_chunk = build_chunk(
        content: "AKIAIOSFODNN7EXAMPLE",
        knowledge_artifact_param: secret_artifact
      )
      in_scope_chunk = build_chunk(
        content: "def hello; puts 'world'; end",
        scope_path: "app/controllers/users_controller.rb"
      )

      scoped = described_class.new(
        project: project,
        qdrant_client: qdrant_client,
        actor: { type: "operator", id: "42" },
        scope_filter: { scope_path: "config/secrets.yml" }
      )

      scoped.call

      expect(in_scope_chunk.reload.status).to eq("active")
      expect(other_chunk.reload.status).to eq("redacted")
    end

    context "when dry_run is true" do
      let(:scrubber) do
        described_class.new(
          project: project,
          qdrant_client: qdrant_client,
          actor: { type: "operator", id: "42" },
          dry_run: true
        )
      end

      it "does not write audit events" do
        build_chunk(content: "GITHUB_TOKEN=ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijkl")

        expect {
          scrubber.call
        }.not_to change(KnowledgeAuditEvent, :count)
      end

      it "does not mutate chunk content" do
        chunk = build_chunk(content: "GITHUB_TOKEN=ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijkl")
        original = chunk.content

        scrubber.call

        expect(chunk.reload.content).to eq(original)
      end

      it "does not delete Qdrant points" do
        build_chunk(content: "GITHUB_TOKEN=ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijkl")

        expect(points).not_to receive(:delete)

        scrubber.call
      end

      it "returns counts of what would have been scrubbed" do
        build_chunk(content: "GITHUB_TOKEN=ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijkl")
        build_chunk(content: "User bob@example.com signed in via SSO.")

        result = scrubber.call

        expect(result.scrubbed_chunks).to eq(0)
        expect(result.skipped_chunks).to eq(2)
      end
    end

    context "when no chunks match" do
      it "does not delete Qdrant points" do
        build_chunk(content: "def hello; puts 'world'; end")

        expect(points).not_to receive(:delete)

        scrubber.call
      end

      it "still emits a summary audit event" do
        expect {
          scrubber.call
        }.to change { KnowledgeAuditEvent.by_event_type("chunks_scrubbed").count }.by(1)
      end
    end

    context "when many chunks need scrubbing" do
      before do
        stub_const("Knowledge::Redaction::Scrubber::DEFAULT_REBUILD_THRESHOLD", 1)
        # First get returns "exists" so drop proceeds; subsequent gets return
        # "not found" so ensure_collection! recreates the schema.
        call_count = 0
        allow(collections).to receive(:get) do
          call_count += 1
          if call_count == 1
            { "result" => { "status" => "green" } }
          else
            raise Qdrant::Error.new("Not found")
          end
        end
      end

      it "rebuilds the Qdrant collection when the threshold is exceeded" do
        build_chunk(content: "GITHUB_TOKEN=ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijkl")

        expect(collections).to receive(:delete).with(collection_name: "account_#{project.account_id}_project_#{project.id}")
        expect(collections).to receive(:create).at_least(:once)

        result = scrubber.call

        expect(result.qdrant_collection_rebuilt).to be(true)
      end

      it "emits a qdrant_collection_scrubbed audit event" do
        build_chunk(content: "GITHUB_TOKEN=ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijkl")

        expect {
          scrubber.call
        }.to change { KnowledgeAuditEvent.by_event_type("qdrant_collection_scrubbed").count }.by(1)
      end
    end

    context "without a qdrant_client" do
      let(:scrubber) do
        described_class.new(
          project: project,
          qdrant_client: nil,
          actor: { type: "operator", id: "42" }
        )
      end

      it "still scrubs PostgreSQL content" do
        chunk = build_chunk(content: "GITHUB_TOKEN=ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijkl")

        scrubber.call

        expect(chunk.reload.status).to eq("redacted")
      end

      it "does not raise on missing Qdrant" do
        build_chunk(content: "GITHUB_TOKEN=ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijkl")

        expect { scrubber.call }.not_to raise_error
      end
    end
  end

  describe "configuration" do
    it "falls back to the default batch size when batch_size is zero" do
      s = described_class.new(project: project, qdrant_client: qdrant_client, batch_size: 0)
      expect(s.batch_size).to eq(described_class::DEFAULT_BATCH_SIZE)
    end

    it "falls back to the default batch size when batch_size is negative" do
      s = described_class.new(project: project, qdrant_client: qdrant_client, batch_size: -1)
      expect(s.batch_size).to eq(described_class::DEFAULT_BATCH_SIZE)
    end

    it "honors a positive batch_size" do
      s = described_class.new(project: project, qdrant_client: qdrant_client, batch_size: 7)
      expect(s.batch_size).to eq(7)
    end

    it "falls back to default actor when none is provided" do
      s = described_class.new(project: project, qdrant_client: qdrant_client, actor: nil)
      expect(s.actor).to eq({ type: "system" })
    end
  end
end
