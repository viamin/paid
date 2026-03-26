# frozen_string_literal: true

require "rails_helper"

RSpec.describe Knowledge::Qdrant::CollectionManager do
  let(:project) { create(:project) }
  let(:qdrant_client) { instance_double(QdrantClient) }
  let(:collections) { instance_double(Qdrant::Collections) }
  let(:points) { instance_double(Qdrant::Points) }
  let(:collection_name) { "project_#{project.id}" }
  let(:manager) { described_class.new(project: project, client: qdrant_client) }

  before do
    allow(qdrant_client).to receive_messages(collections: collections, points: points)
    allow(Paid).to receive(:embedding_dimensions).and_return(3072)
  end

  describe ".collection_name" do
    it "returns project_<id>" do
      expect(described_class.collection_name(project)).to eq("project_#{project.id}")
    end
  end

  describe "#ensure_collection!" do
    context "when the collection already exists" do
      before do
        allow(collections).to receive(:get)
          .with(collection_name: collection_name)
          .and_return({ "result" => { "status" => "green" } })
      end

      it "does not create a new collection" do
        expect(collections).not_to receive(:create)

        manager.ensure_collection!
      end
    end

    context "when the collection does not exist" do
      before do
        allow(collections).to receive(:get)
          .with(collection_name: collection_name)
          .and_raise(Qdrant::Error.new("Not found"))
        allow(collections).to receive_messages(create: { "result" => true }, create_index: { "result" => true })
      end

      it "creates the collection with correct parameters" do
        manager.ensure_collection!

        expect(collections).to have_received(:create).with(
          collection_name: collection_name,
          vectors: { size: 3072, distance: "Cosine" }
        )
      end

      it "creates payload indexes" do
        manager.ensure_collection!

        %w[project_version_id artifact_type status].each do |field|
          expect(collections).to have_received(:create_index).with(
            collection_name: collection_name,
            field_name: field,
            field_schema: "keyword"
          )
        end
      end
    end

    context "when the API returns a non-not-found error" do
      before do
        allow(collections).to receive(:get)
          .with(collection_name: collection_name)
          .and_raise(Qdrant::Error.new("Unauthorized: invalid API key"))
      end

      it "re-raises the error" do
        expect { manager.ensure_collection! }.to raise_error(Qdrant::Error, /Unauthorized/)
      end
    end

    context "when called via class method" do
      before do
        call_count = 0
        allow(collections).to receive(:get).with(collection_name: collection_name) do
          call_count += 1
          if call_count <= 1
            raise Qdrant::Error, "Not found"
          else
            { "result" => { "status" => "green" } }
          end
        end
        allow(collections).to receive_messages(create: { "result" => true }, create_index: { "result" => true })
      end

      it "is idempotent" do
        described_class.ensure_collection!(project, client: qdrant_client)
        described_class.ensure_collection!(project, client: qdrant_client)

        expect(collections).to have_received(:create).once
      end
    end
  end

  describe "#drop_collection!" do
    context "when the collection exists" do
      before do
        allow(collections).to receive(:get)
          .with(collection_name: collection_name)
          .and_return({ "result" => { "status" => "green" } })
        allow(collections).to receive(:delete).and_return({ "result" => true })
      end

      it "deletes the collection" do
        manager.drop_collection!

        expect(collections).to have_received(:delete).with(collection_name: collection_name)
      end
    end

    context "when the collection does not exist" do
      before do
        allow(collections).to receive(:get)
          .with(collection_name: collection_name)
          .and_raise(Qdrant::Error.new("Not found"))
      end

      it "does nothing" do
        expect(collections).not_to receive(:delete)

        manager.drop_collection!
      end
    end
  end

  describe "#rebuild_schema!" do
    before do
      call_count = 0
      allow(collections).to receive(:get).with(collection_name: collection_name) do
        call_count += 1
        if call_count <= 1
          { "result" => { "status" => "green" } }
        else
          raise Qdrant::Error, "Not found"
        end
      end

      allow(collections).to receive_messages(
        delete: { "result" => true },
        create: { "result" => true },
        create_index: { "result" => true }
      )
    end

    it "drops and recreates the collection" do
      manager.rebuild_schema!

      expect(collections).to have_received(:delete).with(collection_name: collection_name)
      expect(collections).to have_received(:create)
    end

    it "does not upsert points (embeddings must be recomputed separately)" do
      manager.rebuild_schema!

      expect(points).not_to have_received(:upsert)
    end

    it "logs a warning" do
      allow(Rails.logger).to receive(:warn)

      manager.rebuild_schema!

      expect(Rails.logger).to have_received(:warn).with(
        hash_including(message: "knowledge.qdrant.rebuild_started")
      )
    end
  end
end
