# frozen_string_literal: true

require "rails_helper"

# @spec PARTIAL-CLOSEOUT-058
RSpec.describe Tools::GetAgentRun do
  let(:user) { create(:user, :member) }
  let(:session) { create(:chat_session, account: user.account, created_by: user) }
  let(:project) { create(:project, account: user.account) }
  let(:tool) { described_class.new(user:, session:) }

  it "exposes post-PR assessment diagnostics through the same read contract" do
    run = create(:agent_run, project:, reconciliation: { "assessment_failure" => {
      "category" => "authentication_unavailable", "provider" => "codex", "request_id" => "request-5184",
      "raw_output" => "private"
    } })

    diagnostic = tool.call(agent_run_id: run.id).fetch(:assessment_diagnostics)

    expect(diagnostic).to include("category" => "authentication_unavailable", "provider" => "codex", "request_id" => "request-5184")
    expect(diagnostic).not_to have_key("raw_output")
  end

  it "exposes bounded diagnostics while dropping raw and malformed payloads" do
    fields = 20.times.map { { "path" => "x" * 200, "expected" => "object", "actual" => "string", "output" => "private" } }
    run = create(:agent_run, project:, reconciliation: { "acceptance_audit_failure" => {
      "category" => "invalid_assessment", "provider" => "p" * 200, "model" => { "private" => "value" },
      "invalid_fields" => [ "malformed", *fields ], "raw_output" => "private"
    } })

    diagnostic = tool.call(agent_run_id: run.id).fetch(:assessment_diagnostics)

    expect(diagnostic).to include("category" => "invalid_assessment", "provider" => "p" * 120, "model" => "Hash")
    expect(diagnostic.fetch("invalid_fields").size).to be <= 10
    expect(diagnostic.fetch("invalid_fields").first).to eq("path" => "x" * 120, "expected" => "object", "actual" => "string")
    expect(diagnostic.to_json).not_to include("private", "malformed", "raw_output")
  end
end
