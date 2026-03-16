# frozen_string_literal: true

require "rails_helper"
require "zlib"
require "stringio"

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

    context "with HTML responses" do
      it "does not compress HTML to mitigate BREACH attacks" do
        get "/users/sign_in", headers: { "Accept-Encoding" => "gzip" }

        expect(response).to have_http_status(:ok)
        expect(response.media_type).to eq("text/html")
        expect(response.headers["Content-Encoding"]).to be_nil
      end
    end
  end
end
