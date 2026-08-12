# frozen_string_literal: true

require "rails_helper"
require "redis"

RSpec.describe "Health" do
  let(:qdrant_client) { instance_double(QdrantClient) }
  let(:redis_client) { instance_double(Redis) }
  let(:temporal_connection) { double("TemporalConnection", connected?: true) } # rubocop:disable RSpec/VerifiedDoubles
  let(:temporal_client) { double("TemporalClient", connection: temporal_connection) } # rubocop:disable RSpec/VerifiedDoubles

  before do
    allow(Paid).to receive_messages(qdrant_client: qdrant_client, temporal_client: temporal_client)
    allow(qdrant_client).to receive(:healthy?).and_return(true)
    allow(Redis).to receive(:new).and_return(redis_client)
    allow(redis_client).to receive(:ping).and_return("PONG")
    allow(redis_client).to receive(:close)
    allow(ActiveRecord::Migration).to receive(:check_all_pending!)
    allow(ENV).to receive(:key?).with("QDRANT_URL").and_return(false)
    allow(ENV).to receive(:key?).with("QDRANT_API_KEY").and_return(false)
  end

  describe "GET /ready" do
    context "when all dependencies are healthy" do
      it "returns 200 with ready status" do
        get "/ready"

        expect(response).to have_http_status(:ok)
        body = response.parsed_body
        expect(body["status"]).to eq("ready")
        expect(body["checks"]["database"]).to eq("ok")
        expect(body["checks"]["migrations"]).to eq("ok")
        expect(body["checks"]["redis"]).to eq("ok")
        expect(body["checks"]["temporal"]).to eq("ok")
      end

      it "does not include qdrant check when not configured" do
        get "/ready"

        body = response.parsed_body
        expect(body["checks"]).not_to have_key("qdrant")
      end
    end

    context "when database is unreachable" do
      before do
        allow(ActiveRecord::Base.connection).to receive(:execute)
          .and_raise(ActiveRecord::ConnectionNotEstablished)
        allow(ActiveRecord::Migration).to receive(:check_all_pending!)
          .and_raise(ActiveRecord::ConnectionNotEstablished)
      end

      it "returns 503 with not_ready status" do
        get "/ready"

        expect(response).to have_http_status(:service_unavailable)
        body = response.parsed_body
        expect(body["status"]).to eq("not_ready")
        expect(body["checks"]["database"]).to eq("failing")
      end
    end

    context "when migrations are pending" do
      before do
        allow(ActiveRecord::Migration).to receive(:check_all_pending!)
          .and_raise(ActiveRecord::PendingMigrationError.new("pending"))
      end

      it "returns 503 with migrations failing" do
        get "/ready"

        expect(response).to have_http_status(:service_unavailable)
        body = response.parsed_body
        expect(body["status"]).to eq("not_ready")
        expect(body["checks"]["migrations"]).to eq("failing")
      end
    end

    context "when Redis is unreachable" do
      before do
        allow(redis_client).to receive(:ping).and_raise(Redis::CannotConnectError)
      end

      it "returns 503 with not_ready status" do
        get "/ready"

        expect(response).to have_http_status(:service_unavailable)
        body = response.parsed_body
        expect(body["status"]).to eq("not_ready")
        expect(body["checks"]["redis"]).to eq("failing")
      end
    end

    context "when Temporal is unreachable" do
      before do
        allow(temporal_connection).to receive(:connected?).and_return(false)
      end

      it "returns 503 with not_ready status" do
        get "/ready"

        expect(response).to have_http_status(:service_unavailable)
        body = response.parsed_body
        expect(body["status"]).to eq("not_ready")
        expect(body["checks"]["temporal"]).to eq("failing")
      end
    end

    context "when Temporal client raises an error" do
      before do
        allow(Paid).to receive(:temporal_client).and_raise(StandardError, "connection refused")
      end

      it "returns 503 with temporal failing" do
        get "/ready"

        expect(response).to have_http_status(:service_unavailable)
        body = response.parsed_body
        expect(body["checks"]["temporal"]).to eq("failing")
      end
    end

    context "when Qdrant is configured" do
      before do
        allow(ENV).to receive(:key?).with("QDRANT_URL").and_return(true)
      end

      context "when Qdrant is healthy" do
        it "includes qdrant check as ok and returns 200" do
          get "/ready"

          expect(response).to have_http_status(:ok)
          body = response.parsed_body
          expect(body["checks"]["qdrant"]).to eq("ok")
        end
      end

      context "when Qdrant is unhealthy" do
        before { allow(qdrant_client).to receive(:healthy?).and_return(false) }

        it "returns 503 with qdrant failing" do
          get "/ready"

          expect(response).to have_http_status(:service_unavailable)
          body = response.parsed_body
          expect(body["checks"]["qdrant"]).to eq("failing")
        end
      end
    end

    it "does not require authentication" do
      get "/ready"

      expect(response).not_to redirect_to(new_user_session_path)
      expect(response).to have_http_status(:ok)
    end
  end

  describe "GET /live" do
    it "returns 200 with alive status" do
      get "/live"

      expect(response).to have_http_status(:ok)
      body = response.parsed_body
      expect(body["status"]).to eq("alive")
    end

    it "does not require authentication" do
      get "/live"

      expect(response).not_to redirect_to(new_user_session_path)
      expect(response).to have_http_status(:ok)
    end
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

  describe "GET /health/liveness" do
    it "returns 200 with alive status" do
      get "/health/liveness"

      expect(response).to have_http_status(:ok)
      body = response.parsed_body
      expect(body["status"]).to eq("alive")
    end

    it "does not require authentication" do
      get "/health/liveness"

      expect(response).not_to redirect_to(new_user_session_path)
      expect(response).to have_http_status(:ok)
    end
  end

  describe "GET /health/readiness" do
    context "when database is healthy and migrations are current" do
      it "returns 200 with ready status" do
        get "/health/readiness"

        expect(response).to have_http_status(:ok)
        body = response.parsed_body
        expect(body["status"]).to eq("ready")
        expect(body["checks"]["database"]).to eq("ok")
        expect(body["checks"]["redis"]).to eq("ok")
        expect(body["checks"]["temporal"]).to eq("ok")
      end
    end

    context "when database is unavailable" do
      before do
        allow(ActiveRecord::Base.connection).to receive(:execute)
          .and_raise(ActiveRecord::ConnectionNotEstablished)
        allow(ActiveRecord::Migration).to receive(:check_all_pending!)
          .and_raise(ActiveRecord::ConnectionNotEstablished)
      end

      it "returns 503 with not_ready status" do
        get "/health/readiness"

        expect(response).to have_http_status(:service_unavailable)
        body = response.parsed_body
        expect(body["status"]).to eq("not_ready")
        expect(body["checks"]["database"]).to eq("failing")
      end
    end

    it "does not require authentication" do
      get "/health/readiness"

      expect(response).not_to redirect_to(new_user_session_path)
      expect(response).to have_http_status(:ok)
    end
  end
end
