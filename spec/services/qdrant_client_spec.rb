# frozen_string_literal: true

require "rails_helper"

RSpec.describe QdrantClient do
  let(:url) { "http://localhost:6333" }
  let(:client) { described_class.new(url: url) }
  let(:qdrant_client) { instance_double(Qdrant::Client) }
  let(:faraday_connection) { instance_double(Faraday::Connection) }
  let(:faraday_options) { Faraday::RequestOptions.new }
  let(:collections) { instance_double(Qdrant::Collections) }
  let(:points) { instance_double(Qdrant::Points) }

  before do
    allow(Qdrant::Client).to receive(:new).and_return(qdrant_client)
    allow(qdrant_client).to receive_messages(connection: faraday_connection, collections: collections, points: points)
    allow(faraday_connection).to receive(:options).and_return(faraday_options)
  end

  describe "#initialize" do
    it "sets default timeouts on the Faraday connection" do
      client

      expect(faraday_options.timeout).to eq(5)
      expect(faraday_options.open_timeout).to eq(3)
    end

    it "accepts custom timeout values" do
      described_class.new(url: url, timeout: 10, open_timeout: 7)

      expect(faraday_options.timeout).to eq(10)
      expect(faraday_options.open_timeout).to eq(7)
    end
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
    it "delegates method calls through the proxy" do
      allow(collections).to receive(:list).and_return({ "result" => [] })
      expect(client.collections.list).to eq({ "result" => [] })
    end
  end

  describe "#points" do
    it "delegates method calls through the proxy" do
      allow(points).to receive(:list).with(collection_name: "test").and_return({ "result" => [] })
      expect(client.points.list(collection_name: "test")).to eq({ "result" => [] })
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

  describe "error wrapping" do
    context "when a collections operation fails with ConnectionFailed" do
      before do
        allow(collections).to receive(:list)
          .and_raise(Faraday::ConnectionFailed.new("Connection refused"))
      end

      it "wraps the error in ConnectionError with context" do
        expect { client.collections.list }
          .to raise_error(QdrantClient::ConnectionError, /Qdrant connection error during #list: Connection refused/)
      end

      it "preserves the original backtrace" do
        expect { client.collections.list }
          .to raise_error(QdrantClient::ConnectionError) { |e| expect(e.backtrace).not_to be_empty }
      end
    end

    context "when a collections operation fails with TimeoutError" do
      before do
        allow(collections).to receive(:list)
          .and_raise(Faraday::TimeoutError.new("timeout"))
      end

      it "wraps the error in ConnectionError with context" do
        expect { client.collections.list }
          .to raise_error(QdrantClient::ConnectionError, /Qdrant connection error during #list: timeout/)
      end
    end

    context "when a points operation fails with ConnectionFailed" do
      before do
        allow(points).to receive(:list).with(collection_name: "test")
          .and_raise(Faraday::ConnectionFailed.new("Connection refused"))
      end

      it "wraps the error in ConnectionError with context" do
        expect { client.points.list(collection_name: "test") }
          .to raise_error(QdrantClient::ConnectionError, /Qdrant connection error during #list: Connection refused/)
      end
    end

    context "when a points operation fails with TimeoutError" do
      before do
        allow(points).to receive(:list).with(collection_name: "test")
          .and_raise(Faraday::TimeoutError.new("timeout"))
      end

      it "wraps the error in ConnectionError with context" do
        expect { client.points.list(collection_name: "test") }
          .to raise_error(QdrantClient::ConnectionError, /Qdrant connection error during #list: timeout/)
      end
    end
  end
end
