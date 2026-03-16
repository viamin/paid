# frozen_string_literal: true

require "rails_helper"
require "zlib"

RSpec.describe "Gzip compression" do
  describe "Rack::Deflater middleware" do
    context "with JSON responses" do
      let(:qdrant_client) { instance_double(QdrantClient) }

      before do
        allow(Paid).to receive(:qdrant_client).and_return(qdrant_client)
        allow(qdrant_client).to receive(:healthy?).and_return(true)
      end

      it "returns valid gzip-encoded JSON when client accepts gzip" do
        get "/health/services", headers: { "Accept-Encoding" => "gzip" }

        expect(response).to have_http_status(:ok)
        expect(response.headers["Content-Encoding"]).to eq("gzip")

        inflated = Zlib::GzipReader.new(StringIO.new(response.body)).read
        parsed = JSON.parse(inflated)
        expect(parsed).to have_key("status")
      end

      it "returns uncompressed JSON when client does not accept gzip" do
        get "/health/services", headers: { "Accept-Encoding" => "identity" }

        expect(response).to have_http_status(:ok)
        expect(response.headers["Content-Encoding"]).to be_nil

        parsed = response.parsed_body
        expect(parsed).to have_key("status")
      end
    end

    it "excludes text/html from compression to mitigate BREACH attacks" do
      deflater_config = Rails.application.config.middleware.detect { |m| m.name == "Rack::Deflater" }
      include_types = deflater_config.args.first[:include]

      expect(include_types).not_to include("text/html")
      expect(include_types).to include("application/json")
    end
  end
end
