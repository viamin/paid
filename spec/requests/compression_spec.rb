# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Gzip compression" do
  describe "Rack::Deflater middleware" do
    it "returns gzip-encoded response when client accepts gzip" do
      get "/up", headers: { "Accept-Encoding" => "gzip" }

      expect(response).to have_http_status(:ok)
      expect(response.headers["Content-Encoding"]).to eq("gzip")
    end

    it "returns uncompressed response when client does not accept gzip" do
      get "/up", headers: { "Accept-Encoding" => "identity" }

      expect(response).to have_http_status(:ok)
      expect(response.headers["Content-Encoding"]).to be_nil
    end
  end
end
