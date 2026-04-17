# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Api::Metrics" do
  describe "GET /api/metrics" do
    it "returns 200 with Prometheus text content type" do
      get "/api/metrics"

      expect(response).to have_http_status(:ok)
      expect(response.content_type).to include("text/plain")
      expect(response.content_type).to include("version=0.0.4")
    end

    it "does not require authentication" do
      get "/api/metrics"

      expect(response).not_to redirect_to(new_user_session_path)
      expect(response).to have_http_status(:ok)
    end

    it "returns Prometheus-formatted metrics" do
      get "/api/metrics"

      body = response.body
      expect(body).to include("# HELP paid_agent_runs_total")
      expect(body).to include("# TYPE paid_agent_runs_total gauge")
      expect(body).to include("paid_agent_runs_active")
      expect(body).to include("paid_goodjob_queue_depth")
      expect(body).to include("paid_containers_active")
      expect(body).to include("paid_service_containers_total")
      expect(body).to include("paid_temporal_workflow_slots_total")
    end
  end
end
