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
  let(:collection_name) { "project_#{project.id}" }
  let(:vector) { Array.new(3072, 0.1) }

  before do
    allow(qdrant_client).to receive(:points).and_return(points)
  end

  describe ".upsert_chunk!" do
    before do
      allow(points).to receive(:upsert).and_return({ "result" => { "status" => "completed" } })
    end

    it "upserts a point with the correct payload" do
      described_class.upsert_chunk!(chunk, vector: vector, client: qdrant_client)

      expect(points).to have_received(:upsert).with(
        collection_name: collection_name,
        points: [
          {
            id: chunk.id,
            vector: vector,
            payload: {
              project_id: project.id,
              project_version_id: project_version.id,
              artifact_type: "route",
              scope_tags: [ "controller", "api" ],
              status: "active",
              created_at: chunk.created_at.iso8601
            }
          }
        ],
        wait: true
      )
    end

    it "uses the chunk UUID as the point ID" do
      described_class.upsert_chunk!(chunk, vector: vector, client: qdrant_client)

      expect(points).to have_received(:upsert) do |args|
        point = args[:points].first
        expect(point[:id]).to eq(chunk.id)
        expect(point[:id]).to match(/\A[0-9a-f-]{36}\z/)
      end
    end
  end

  describe ".delete_chunks!" do
    before do
      allow(points).to receive(:delete).and_return({ "result" => { "status" => "completed" } })
    end

    it "deletes points by UUID" do
      chunk_ids = [ SecureRandom.uuid, SecureRandom.uuid ]

      described_class.delete_chunks!(chunk_ids, project: project, client: qdrant_client)

      expect(points).to have_received(:delete).with(
        collection_name: collection_name,
        points: chunk_ids.map(&:to_s),
        wait: true
      )
    end

    it "does nothing when given an empty array" do
      described_class.delete_chunks!([], project: project, client: qdrant_client)

      expect(points).not_to have_received(:delete)
    end
  end

  describe ".delete_by_filter!" do
    before do
      allow(points).to receive(:delete).and_return({ "result" => { "status" => "completed" } })
    end

    it "deletes points matching the project filter" do
      described_class.delete_by_filter!(project: project, client: qdrant_client)

      expect(points).to have_received(:delete).with(
        collection_name: collection_name,
        filter: {
          must: [
            { key: "project_id", match: { value: project.id } }
          ]
        },
        wait: true
      )
    end

    it "includes additional filters" do
      described_class.delete_by_filter!(
        project: project,
        filters: { artifact_type: "route", status: "stale" },
        client: qdrant_client
      )

      expect(points).to have_received(:delete).with(
        collection_name: collection_name,
        filter: {
          must: [
            { key: "project_id", match: { value: project.id } },
            { key: "artifact_type", match: { value: "route" } },
            { key: "status", match: { value: "stale" } }
          ]
        },
        wait: true
      )
    end
  end
end
