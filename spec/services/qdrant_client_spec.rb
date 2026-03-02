# frozen_string_literal: true

require "rails_helper"

RSpec.describe QdrantClient do
  let(:url) { "http://localhost:6333" }
  let(:client) { described_class.new(url: url) }
  let(:qdrant_client) { instance_double(Qdrant::Client) }
  let(:collections) { instance_double(Qdrant::Collections) }

  before do
    allow(Qdrant::Client).to receive(:new).and_return(qdrant_client)
    allow(qdrant_client).to receive(:collections).and_return(collections)
    allow(qdrant_client).to receive(:points)
  end

  describe "#healthy?" do
    context "when Qdrant is reachable" do
      before { allow(collections).to receive(:list).and_return({ "result" => [] }) }

      it "returns true" do
        expect(client.healthy?).to be true
      end
    end

    context "when Qdrant is unreachable" do
      before { allow(collections).to receive(:list).and_raise(Faraday::ConnectionFailed.new("Connection refused")) }

      it "returns false" do
        expect(client.healthy?).to be false
      end
    end
  end

  describe "#collections" do
    it "delegates to the underlying client" do
      expect(client.collections).to eq(collections)
    end
  end

  describe "#points" do
    let(:points) { instance_double(Qdrant::Points) }

    before { allow(qdrant_client).to receive(:points).and_return(points) }

    it "delegates to the underlying client" do
      expect(client.points).to eq(points)
    end
  end

  describe "error hierarchy" do
    it "defines Error as a StandardError subclass" do
      expect(QdrantClient::Error.new).to be_a(StandardError)
    end

    it "defines ConnectionError as an Error subclass" do
      expect(QdrantClient::ConnectionError.new).to be_a(QdrantClient::Error)
    end
  end
end
