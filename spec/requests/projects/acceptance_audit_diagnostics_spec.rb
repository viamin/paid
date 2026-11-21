# frozen_string_literal: true

require "rails_helper"

# @spec PARTIAL-CLOSEOUT-058
RSpec.describe "Acceptance audit diagnostics" do
  let(:user) { create(:user, :owner) }
  let(:project) { create(:project, account: user.account, created_by: user) }
  let(:diagnostic) do
    { "category" => "invalid_assessment", "provider" => "opencode", "model" => "glm-5.3",
      "request_id" => "request-5184", "attempt_id" => "attempt-5184",
      "invalid_fields" => [ { "path" => "criteria[0].state", "expected" => "supported state", "actual" => "string" } ],
      "raw_output" => "private-response-5184" }
  end
  let(:run) { create(:agent_run, project:, status: "failed", reconciliation: { "acceptance_audit_failure" => diagnostic }) }

  before { sign_in user }

  it "shows actionable recorded fields and correlation identities" do
    get project_agent_run_path(project, run)

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Assessment diagnostics", "criteria[0].state", "supported state", "glm-5.3")
    expect(response.body).to include("request-5184", "attempt-5184")
    expect(response.body).not_to include("private-response-5184")
  end

  it "escapes field diagnostics and safely handles malformed field entries" do
    diagnostic["provider"] = "<script>alert(5184)</script>"
    diagnostic["invalid_fields"] << "not a field object"

    get project_agent_run_path(project, run)

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("&lt;script&gt;alert(5184)&lt;/script&gt;")
    expect(response.body).not_to include("<script>alert(5184)</script>", "not a field object")
  end

  it "tolerates a malformed legacy diagnostic value" do
    run.update!(reconciliation: { "acceptance_audit_failure" => "legacy invalid value" })

    get project_agent_run_path(project, run)

    expect(response).to have_http_status(:ok)
    expect(response.body).not_to include("Assessment diagnostics", "legacy invalid value")
  end

  it "shows the same bounded diagnostics from post-PR reconciliation" do
    run.update!(reconciliation: { "assessment_failure" => diagnostic, "failed_at" => "2026-11-21T12:34:56Z" })

    get project_agent_run_path(project, run)

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Assessment diagnostics", "criteria[0].state", "glm-5.3", "2026-11-21T12:34:56Z")
    expect(response.body).not_to include("private-response-5184")
  end

  it "does not expose a foreign tenant's diagnostics" do
    foreign = create(:agent_run, status: "failed", reconciliation: { "acceptance_audit_failure" => diagnostic })

    get project_agent_run_path(foreign.project, foreign)

    expect(response).to have_http_status(:not_found)
  end
end
