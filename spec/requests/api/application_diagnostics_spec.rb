# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Application diagnostics proxy" do
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
