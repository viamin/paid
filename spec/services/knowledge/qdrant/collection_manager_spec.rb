# frozen_string_literal: true

require "rails_helper"

RSpec.describe Knowledge::Qdrant::CollectionManager do
  let(:project) { create(:project) }
  let(:qdrant_client) { instance_double(QdrantClient) }
  let(:collections) { instance_double(Qdrant::Collections) }
  let(:points) { instance_double(Qdrant::Points) }
  let(:collection_name) { "account_#{project.account_id}_project_#{project.id}" }
  let(:legacy_collection_name) { "project_#{project.id}" }
  let(:manager) { described_class.new(project: project, client: qdrant_client) }

  before do
    allow(qdrant_client).to receive_messages(collections: collections, points: points)
    allow(Paid).to receive(:embedding_dimensions).and_return(3072)
  end

  describe ".collection_name" do
    it "returns an account and project scoped name" do
      expect(described_class.collection_name(project)).to eq("account_#{project.account_id}_project_#{project.id}")
    end
  end

  describe "#ensure_collection!" do
    context "when the collection already exists" do
      before do
        allow(collections).to receive(:get)
          .with(collection_name: collection_name)
          .and_return({ "result" => { "status" => "green" } })
        allow(collections).to receive(:get)
          .with(collection_name: legacy_collection_name)
          .and_raise(Qdrant::Error.new("Not found"))
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
        allow(collections).to receive(:get)
          .with(collection_name: legacy_collection_name)
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

      it "creates payload indexes with correct field schemas" do
        manager.ensure_collection!

        {
          "account_id" => "integer",
          "project_version_id" => "integer",
          "artifact_type" => "keyword",
          "status" => "keyword"
        }.each do |field_name, field_schema|
          expect(collections).to have_received(:create_index).with(
            collection_name: collection_name,
            field_name: field_name,
            field_schema: field_schema
          )
        end
      end
    end

    context "when only the legacy project-scoped collection exists" do
      before do
        allow(collections).to receive(:get)
          .with(collection_name: collection_name)
          .and_raise(Qdrant::Error.new("Not found"))
        allow(collections).to receive(:get)
          .with(collection_name: legacy_collection_name)
          .and_return({ "result" => { "status" => "green" } })
        allow(collections).to receive_messages(create_index: { "result" => true }, update_aliases: { "result" => true })
        allow(points).to receive(:set_payload).and_return({ "result" => true })
      end

      it "migrates the legacy collection before aliasing the tenant-scoped name" do
        expect(collections).not_to receive(:create)

        manager.ensure_collection!

        expect_legacy_collection_migrated
        expect(collections).to have_received(:update_aliases).with(
          actions: [
            {
              create_alias: {
                collection_name: legacy_collection_name,
                alias_name: collection_name
              }
            }
          ]
        )
      end
    end

    context "when the tenant-scoped alias already points at the legacy collection" do
      before do
        allow(collections).to receive(:get)
          .with(collection_name: collection_name)
          .and_return({ "result" => { "status" => "green" } })
        allow(collections).to receive(:get)
          .with(collection_name: legacy_collection_name)
          .and_return({ "result" => { "status" => "green" } })
        allow(collections).to receive(:create_index).and_return({ "result" => true })
        allow(points).to receive(:set_payload).and_return({ "result" => true })
      end

      it "migrates legacy payloads without recreating the alias" do
        expect(collections).not_to receive(:update_aliases)

        manager.ensure_collection!

        expect_legacy_collection_migrated
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
        allow(collections).to receive(:get)
          .with(collection_name: legacy_collection_name)
          .and_raise(Qdrant::Error.new("Not found"))
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
      allow(collections).to receive(:get)
        .with(collection_name: legacy_collection_name)
        .and_raise(Qdrant::Error.new("Not found"))

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
      expect(points).not_to receive(:upsert)

      manager.rebuild_schema!
    end

    it "logs a warning" do
      allow(Rails.logger).to receive(:warn)

      manager.rebuild_schema!

      expect(Rails.logger).to have_received(:warn).with(
        hash_including(message: "knowledge.qdrant.rebuild_started")
      )
    end
  end

  def expect_legacy_collection_migrated
    expect(collections).to have_received(:create_index).with(
      collection_name: legacy_collection_name,
      field_name: "account_id",
      field_schema: "integer"
    )
    expect(points).to have_received(:set_payload).with(
      collection_name: legacy_collection_name,
      payload: { account_id: project.account_id },
      filter: {},
      wait: true
    )
  end
end
