# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Application diagnostics proxy" do
  # @spec APP-DIAGNOSTICS-004
  it "makes a bounded captured log available to the active authenticated run" do
    agent_run = create(:agent_run, :running)
    headers = {
      "X-Agent-Run-Id" => agent_run.id.to_s,
      "X-Proxy-Token" => agent_run.ensure_proxy_token!,
      "CONTENT_TYPE" => "text/plain"
    }

    put "/api/proxy/application-diagnostics", params: "boot token=super-secret-value", headers: headers

    expect(response).to have_http_status(:no_content)

    get "/api/proxy/application-diagnostics", headers: headers

    diagnostics = JSON.parse(response.body)
    expect(diagnostics.dig("logs", "entries", 0, "content")).to include("[REDACTED")
  end

  # @spec APP-DIAGNOSTICS-004
  it "rejects an oversized captured log without changing retained evidence" do
    agent_run = create(:agent_run, :running)
    agent_run.update!(verification_result: { "app_log_tail" => "retained" })
    headers = {
      "X-Agent-Run-Id" => agent_run.id.to_s,
      "X-Proxy-Token" => agent_run.ensure_proxy_token!,
      "CONTENT_TYPE" => "text/plain"
    }

    put "/api/proxy/application-diagnostics", params: "x" * (32.kilobytes + 1), headers: headers

    expect(response).to have_http_status(:payload_too_large)
    expect(agent_run.reload.verification_result.fetch("app_log_tail")).to eq("retained")
  end

  # @spec APP-DIAGNOSTICS-004
  it "treats a blank captured log as a no-capture and preserves retained evidence" do
    agent_run = create(:agent_run, :running)
    agent_run.update!(verification_result: { "app_log_tail" => "retained prior tail" })
    headers = {
      "X-Agent-Run-Id" => agent_run.id.to_s,
      "X-Proxy-Token" => agent_run.ensure_proxy_token!,
      "CONTENT_TYPE" => "text/plain"
    }

    put "/api/proxy/application-diagnostics", params: "   \n", headers: headers

    expect(response).to have_http_status(:no_content)
    expect(agent_run.reload.verification_result).to include("app_log_tail" => "retained prior tail")
  end

  # @spec APP-DIAGNOSTICS-004
  it "rejects captures beyond the per-run budget without changing retained evidence" do
    agent_run = create(:agent_run, :running)
    agent_run.update!(verification_result: { "app_log_tail" => "retained" })
    headers = {
      "X-Agent-Run-Id" => agent_run.id.to_s,
      "X-Proxy-Token" => agent_run.ensure_proxy_token!,
      "CONTENT_TYPE" => "text/plain"
    }
    allow(Rails.cache).to receive(:increment)
      .and_return(Api::ApplicationDiagnosticsController::CAPTURE_RATE_LIMIT_MAX_REQUESTS + 1)

    put "/api/proxy/application-diagnostics", params: "one capture too many", headers: headers

    expect(response).to have_http_status(:too_many_requests)
    expect(agent_run.reload.verification_result.fetch("app_log_tail")).to eq("retained")
  end

  # @spec APP-DIAGNOSTICS-003
  it "binds diagnostics to the run authenticated by the proxy token" do
    agent_run = create(:agent_run, :running)
    other_run = create(:agent_run, :running, project: agent_run.project)
    other_run.update!(verification_result: { "app_log_tail" => "other run only" })

    get "/api/proxy/application-diagnostics", headers: {
      "X-Agent-Run-Id" => agent_run.id.to_s,
      "X-Proxy-Token" => agent_run.ensure_proxy_token!
    }

    expect(response).to have_http_status(:ok)
    expect(JSON.parse(response.body).dig("provenance", "agent_run_id")).to eq(agent_run.id)
    expect(JSON.parse(response.body).dig("logs", "status")).to eq("unavailable")
  end
end
