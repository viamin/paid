# frozen_string_literal: true

require "rails_helper"

RSpec.describe Knowledge::Qdrant::PointSync do
  let(:project) { create(:project) }
  let(:project_version) { create(:project_version, project: project) }
  let(:collector_run) { create(:collector_run, project_version: project_version, collector_type: "routes") }
  let(:artifact) do
    create(:knowledge_artifact,
      collector_run: collector_run,
      project: project,
      artifact_type: "route")
  end
  let(:chunk) { create(:knowledge_chunk, knowledge_artifact: artifact, project: project) }
  let(:client) { QdrantClient.new(url: Paid.qdrant_url, api_key: Paid.qdrant_api_key, timeout: 5, open_timeout: 5) }
  let(:manager) { Knowledge::Qdrant::CollectionManager.new(project: project, client: client) }
  let(:vector) { [ 0.1, 0.2, 0.3, 0.4 ] }
  let(:collection_name) { Knowledge::Qdrant::CollectionManager.collection_name(project) }

  before do
    skip "Qdrant not available at #{Paid.qdrant_url}" unless qdrant_available?
    WebMock.disable_net_connect!(allow_localhost: true, allow: [ /#{Regexp.escape(Paid.qdrant_url)}/ ])
    allow(Paid).to receive(:embedding_dimensions).and_return(vector.size)
    manager.drop_collection!
  end

  after do
    manager.drop_collection! if qdrant_available?
  ensure
    WebMock.disable_net_connect!(allow_localhost: true)
  end

  it "creates a collection and can search an upserted chunk" do
    manager.ensure_collection!

    described_class.upsert_chunk!(chunk, vector: vector, client: client)

    results = client.points.search(
      collection_name: collection_name,
      vector: vector,
      limit: 5,
      with_payload: true
    ).fetch("result")

    expect(results).not_to be_empty
    expect(results.first.fetch("id")).to eq(chunk.id)
    expect(results.first.fetch("payload")).to include(
      "project_id" => project.id,
      "project_version_id" => project_version.id,
      "artifact_type" => artifact.artifact_type,
      "status" => chunk.status
    )
  end

  it "deletes points by filter" do
    manager.ensure_collection!
    described_class.upsert_chunk!(chunk, vector: vector, client: client)

    described_class.delete_by_filter!(
      project: project,
      filters: { artifact_type: artifact.artifact_type },
      client: client
    )

    results = client.points.search(
      collection_name: collection_name,
      vector: vector,
      limit: 5,
      with_payload: false
    ).fetch("result")

    expect(results).to be_empty
  end

  def qdrant_available?
    WebMock.disable_net_connect!(allow_localhost: true, allow: [ /#{Regexp.escape(Paid.qdrant_url)}/ ])
    QdrantClient.new(url: Paid.qdrant_url, api_key: Paid.qdrant_api_key, timeout: 2, open_timeout: 2).healthy?
  rescue StandardError
    false
  ensure
    WebMock.disable_net_connect!(allow_localhost: true)
  end
end
