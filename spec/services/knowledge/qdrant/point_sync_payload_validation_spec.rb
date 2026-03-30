# frozen_string_literal: true

require "rails_helper"

RSpec.describe Knowledge::Qdrant::PointSync do
  let(:project) { create(:project) }
  let(:project_version) { create(:project_version, project: project) }
  let(:collector_run) { create(:collector_run, project_version: project_version) }
  let(:artifact) { create(:knowledge_artifact, collector_run: collector_run, project: project) }
  let(:chunk) { create(:knowledge_chunk, knowledge_artifact: artifact, project: project) }
  let(:qdrant_client) { instance_double(QdrantClient) }
  let(:points) { instance_double(Qdrant::Points) }
  let(:vector) { Array.new(3072, 0.1) }

  before do
    allow(qdrant_client).to receive(:points).and_return(points)
    allow(points).to receive(:upsert).and_return({ "result" => { "status" => "completed" } })
  end

  describe "FORBIDDEN_PAYLOAD_KEYS" do
    it "includes content, text, body, and secret-related keys" do
      expect(described_class::FORBIDDEN_PAYLOAD_KEYS).to include(
        "content", "text", "body", "secret", "password", "token"
      )
    end
  end

  describe "#upsert_chunk! payload safety" do
    it "succeeds with safe payload keys" do
      expect {
        described_class.upsert_chunk!(chunk, vector: vector, client: qdrant_client)
      }.not_to raise_error
    end

    it "does not include content in the Qdrant payload" do
      described_class.upsert_chunk!(chunk, vector: vector, client: qdrant_client)

      expect(points).to have_received(:upsert) do |args|
        payload = args[:points].first[:payload]
        expect(payload.keys.map(&:to_s)).not_to include(*described_class::FORBIDDEN_PAYLOAD_KEYS)
      end
    end

    it "raises ForbiddenPayloadError when payload contains a forbidden key" do
      sync = described_class.new(client: qdrant_client)

      # Stub build_payload to inject a forbidden key, exercising the public upsert_chunk! path
      allow(sync).to receive(:build_payload).and_return({ project_id: 1, content: "leaked" })

      expect { sync.upsert_chunk!(chunk, vector: vector) }
        .to raise_error(Knowledge::Qdrant::ForbiddenPayloadError, /Forbidden payload keys.*content/)
    end

    it "raises ForbiddenPayloadError listing all forbidden keys present" do
      sync = described_class.new(client: qdrant_client)
      allow(sync).to receive(:build_payload).and_return({ content: "x", token: "y", project_id: 1 })

      expect { sync.upsert_chunk!(chunk, vector: vector) }
        .to raise_error(Knowledge::Qdrant::ForbiddenPayloadError, /content.*token|token.*content/)
    end
  end
end
