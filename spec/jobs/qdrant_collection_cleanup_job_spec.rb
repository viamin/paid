# frozen_string_literal: true

require "rails_helper"

RSpec.describe QdrantCollectionCleanupJob do
  let(:qdrant_client) { instance_double(QdrantClient) }
  let(:collections) { instance_double(Qdrant::Collections) }

  before do
    allow(Paid).to receive(:qdrant_client).and_return(qdrant_client)
    allow(qdrant_client).to receive(:collections).and_return(collections)
  end

  it "drops the collection for the given project ID" do
    allow(collections).to receive(:get)
      .with(collection_name: "project_42")
      .and_return({ "result" => { "status" => "green" } })
    allow(collections).to receive(:delete).and_return({ "result" => true })

    described_class.perform_now(42)

    expect(collections).to have_received(:delete).with(collection_name: "project_42")
  end

  it "retries on connection errors" do
    expect(described_class.rescue_handlers).to include(
      a_collection_including("QdrantClient::ConnectionError")
    )
  end
end
