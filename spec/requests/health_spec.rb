# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Health" do
  let(:qdrant_client) { instance_double(QdrantClient) }

  before do
    allow(Paid).to receive(:qdrant_client).and_return(qdrant_client)
  end

  describe "GET /health/services" do
    context "when all services are healthy" do
      before { allow(qdrant_client).to receive(:healthy?).and_return(true) }

      it "returns 200 with ok status" do
        get "/health/services"

        expect(response).to have_http_status(:ok)
        body = response.parsed_body
        expect(body["status"]).to eq("ok")
        expect(body["services"]["qdrant"]).to eq("ok")
      end
    end

    context "when Qdrant is unhealthy" do
      before { allow(qdrant_client).to receive(:healthy?).and_return(false) }

      it "returns 503 with degraded status" do
        get "/health/services"

        expect(response).to have_http_status(:service_unavailable)
        body = response.parsed_body
        expect(body["status"]).to eq("degraded")
        expect(body["services"]["qdrant"]).to eq("unavailable")
      end
    end

    context "when healthy? raises an unexpected exception" do
      before { allow(qdrant_client).to receive(:healthy?).and_raise(StandardError, "unexpected") }

      it "returns 503 with degraded status" do
        get "/health/services"

        expect(response).to have_http_status(:service_unavailable)
        body = response.parsed_body
        expect(body["status"]).to eq("degraded")
        expect(body["services"]["qdrant"]).to eq("unavailable")
      end
    end

    it "does not require authentication" do
      allow(qdrant_client).to receive(:healthy?).and_return(true)

      get "/health/services"

      expect(response).not_to redirect_to(new_user_session_path)
      expect(response).to have_http_status(:ok)
    end
  end
end
