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
  end

  describe "#validate_payload!" do
    subject(:sync) { described_class.new(client: qdrant_client) }

    described_class::FORBIDDEN_PAYLOAD_KEYS.each do |key|
      it "raises SecurityError when payload contains '#{key}'" do
        payload = { project_id: 1, key.to_sym => "some value" }

        expect { sync.send(:validate_payload!, payload) }
          .to raise_error(SecurityError, /Forbidden payload keys.*#{key}/)
      end
    end

    it "allows safe payload keys" do
      payload = { project_id: 1, artifact_type: "route", status: "active" }

      expect { sync.send(:validate_payload!, payload) }.not_to raise_error
    end

    it "raises with multiple forbidden keys listed" do
      payload = { content: "x", token: "y", project_id: 1 }

      expect { sync.send(:validate_payload!, payload) }
        .to raise_error(SecurityError, /content.*token|token.*content/)
    end
  end
end
