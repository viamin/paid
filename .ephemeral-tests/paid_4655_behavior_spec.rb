# frozen_string_literal: true

require "rails_helper"
require "ostruct"

# Reviewed operational acceptance probe for PR #4720's recorded merge.
# Only the external GitHub and agent_harness boundaries are substituted.
RSpec.describe "Paid closeout recovery acceptance" do
  let(:project) { create(:project) }
  let(:issue) { create(:issue, :in_progress, project:, github_state: "open") }
  let(:run) { create(:agent_run, :completed, project:, issue:, pull_request_number: 99) }
  let(:activity) { Activities::ReconcilePartialCloseoutActivity.new }
  let(:credential) do
    create(:runner_credential, account: project.account, runner_key: "claude",
      auth_kind: "oauth_token", token: "initial-fixture-token", long_lived: true)
  end
  let(:client) { instance_double(GithubClient) }
  let(:valid_response) { Struct.new(:output, :success?).new({ gaps: [] }.to_json, true) }

  before do
    credential
    stub_const("ENV", ENV.to_hash.except("ANTHROPIC_API_KEY"))
    allow(GithubClient).to receive(:new).and_return(client)
    allow(client).to receive(:update_issue)
    allow(client).to receive(:issue) { OpenStruct.new(body: issue.body.to_s) }
  end

  it "recovers after credential repair and reuses a successful assessment", :recovery do
    attempts = 0
    allow(AgentHarness).to receive(:send_message) do |_prompt, **options|
      attempts += 1
      expect(options.dig(:provider_runtime, :env, "CLAUDE_CODE_OAUTH_TOKEN"))
        .to eq(credential.reload.token)
      raise AgentHarness::AuthenticationError, "Not logged in" if attempts == 1

      valid_response
    end

    expect { activity.execute(agent_run_id: run.id) }
      .to raise_error(Llm::AnalyzePartialCloseout::AssessmentFailure, /Reconnect/)
    expect(run.reload.reconciliation.dig("assessment_failure", "category"))
      .to eq("authentication_unavailable")
    expect(run.reconciliation).not_to have_key("assessment")
    expect(issue.reload.github_state).to eq("open")

    credential.update!(token: "repaired-fixture-token")
    result = activity.execute(agent_run_id: run.id)
    expect(result).to include(status: "reconciled", gaps_remain: false)
    expect(run.reload.reconciliation.dig("assessment", "gaps")).to eq([])
    expect(run.status).to eq("completed")
    expect(run.pull_request_number).to eq(99)

    activity.execute(agent_run_id: run.id)
    expect(attempts).to eq(2)
  end

  [
    [ :authentication, "authentication_unavailable", /Reconnect.*credential.*retry/i ],
    [ :unavailable, "unsuccessful_response", /transport.*recovery/i ]
  ].each do |failure_kind, category, guidance|
    it "persists actionable #{failure_kind} recovery without accepting the issue", :diagnostics do
      allow(AgentHarness).to receive(:send_message) do
        raise AgentHarness::AuthenticationError, "Not logged in" if failure_kind == :authentication

        Struct.new(:output, :success?).new("", false)
      end

      expect { activity.execute(agent_run_id: run.id) }
        .to raise_error(Llm::AnalyzePartialCloseout::AssessmentFailure, guidance)
      record = run.reload.reconciliation
      expect(record["status"]).to eq("retryable_failure")
      expect(record["error"]).to match(guidance)
      diagnostic = record.fetch("assessment_failure")
      expect(diagnostic).to include("category" => category, "provider" => "claude")
      expect(diagnostic["request_id"]).to be_present
      expect(diagnostic["attempt_id"]).to be_present
      expect(diagnostic["model"]).to be_present
      expect(diagnostic.to_json).not_to include(credential.token)
      expect(record).not_to have_key("assessment")
      expect(issue.reload.github_state).to eq("open")
      expect(client).not_to have_received(:update_issue)
    end
  end
end
