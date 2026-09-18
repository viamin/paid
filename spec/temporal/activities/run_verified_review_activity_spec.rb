# frozen_string_literal: true

require "rails_helper"

RSpec.describe Activities::RunVerifiedReviewActivity do
  let(:project) { create(:project) }
  let(:agent_run) do
    create(:agent_run, project: project, goal: "review",
      source_pull_request_number: 42, status: "queued")
  end
  let(:activity) { described_class.new }
  let(:pipeline_result) do
    {
      outcome: "posted_findings",
      review_id: 555,
      review_url: "https://github.com/o/r/pull/42#pullrequestreview-555",
      comments_posted: 2,
      metrics: {
        attempts: 1, outcome: "posted_findings", candidates: 3,
        verdicts: { confirmed: 2, plausible: 1, refuted: 0 },
        confirmed_groups: 2, comments_posted: 2, unanchored_findings: 0,
        plausible_withheld: 1,
        llm_calls: { find: 1, verify: 3, synthesize: 1 },
        latency_ms: { find: 100, verify: 300, synthesize: 50, post: 20, total: 470 },
        models: [ "claude-sonnet-4-6" ], tokens_input: 1000, tokens_output: 300,
        cost_cents: 2
      }
    }
  end

  before do
    allow(Reviews::Verification::Pipeline).to receive(:call).and_return(pipeline_result)
    allow(ProcessRunQueueJob).to receive(:perform_later)
  end

  # @spec REVIEW-VERIFY-009
  it "runs the pipeline, records a verified_review phase, and returns its result" do
    result = activity.execute({ agent_run_id: agent_run.id })

    expect(Reviews::Verification::Pipeline).to have_received(:call).with(agent_run: agent_run)
    expect(result[:outcome]).to eq("posted_findings")
    expect(result[:agent_run_id]).to eq(agent_run.id)

    phase = agent_run.agent_run_phases.find_by(phase_key: "verified_review")
    expect(phase).to be_present
    expect(phase.phase_group).to eq("agent")
    expect(phase.metadata["candidates"]).to eq(3)
    expect(phase.metadata["verdicts"]).to eq("confirmed" => 2, "plausible" => 1, "refuted" => 0)
    expect(phase.metadata["outcome"]).to eq("posted_findings")
    expect(phase.metadata.keys.map(&:to_s).join(" ")).not_to match(/summary|patch|diff_body/i)
  end

  it "starts the run before the pipeline executes" do
    activity.execute({ agent_run_id: agent_run.id })

    expect(agent_run.reload).to be_running
    expect(agent_run.started_at).to be_present
  end

  # @spec REVIEW-VERIFY-009
  it "logs a system agent-run entry with the metrics summary" do
    activity.execute({ agent_run_id: agent_run.id })

    entry = agent_run.agent_run_logs.find_by(log_type: "system")
    expect(entry.content).to include("posted_findings")
    expect(entry.content).to include('"candidates":3')
    expect(entry.content).not_to include("app/")
  end

  it "marks the phase failed when the pipeline raises" do
    allow(Reviews::Verification::Pipeline).to receive(:call)
      .and_raise(Reviews::Verification::VerifyCandidates::Error.new("verifier exploded"))

    expect {
      activity.execute({ agent_run_id: agent_run.id })
    }.to raise_error(Reviews::Verification::VerifyCandidates::Error)

    phase = agent_run.agent_run_phases.find_by(phase_key: "verified_review")
    expect(phase.status).to eq("failed")
    expect(phase.metadata["error_class"]).to eq("Reviews::Verification::VerifyCandidates::Error")
  end
end
