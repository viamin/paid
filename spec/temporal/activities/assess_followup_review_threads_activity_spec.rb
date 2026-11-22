# frozen_string_literal: true

require "rails_helper"

RSpec.describe Activities::AssessFollowupReviewThreadsActivity do
  let(:project) { create(:project) }
  let(:agent_run) { create(:agent_run, :running, project: project, source_pull_request_number: 42, custom_prompt: "Fix feedback") }
  let(:github_client) { instance_double(GithubClient) }
  let(:response) { instance_double(AgentHarness::Response, success?: true, output: output) }
  let(:output) do
    { head_sha: "current-head", resolutions: [ { thread_id: "thread_1", disposition: "repaired", rationale: "The current head validates the missing input." } ] }.to_json
  end

  before do
    allow(GithubClient).to receive(:new).and_return(github_client)
    allow(github_client).to receive(:pull_request).with(project.full_name, 42)
      .and_return(double(head: double(sha: "current-head")))
    allow(github_client).to receive(:review_threads).with(project.full_name, 42)
      .and_return([ { id: "thread_1", is_resolved: false, comments: [ { body: "Validate input" } ] } ])
    allow(github_client).to receive(:detailed_pull_request_files).with(project.full_name, 42)
      .and_return([ { filename: "app/services/input.rb", patch: "+validate(input)" } ])
    allow(Llm::Request).to receive(:call).and_return(response)
  end

  # @spec FOCUSED-RUN-010
  it "authorizes only captured threads with current-head rationale" do
    result = described_class.new.execute(agent_run_id: agent_run.id, thread_ids: [ "thread_1" ])

    expect(result).to eq(
      authorized: true,
      head_sha: "current-head",
      thread_ids: [ "thread_1" ],
      rationales: { "thread_1" => "The current head validates the missing input." }
    )
  end

  it "fails closed for setup-only output" do
    allow(response).to receive(:output).and_return("setup completed")

    expect(described_class.new.execute(agent_run_id: agent_run.id, thread_ids: [ "thread_1" ])).to include(authorized: false)
  end

  it "fails closed when the response names an uncaptured thread" do
    allow(response).to receive(:output).and_return(
      { head_sha: "current-head", resolutions: [ { thread_id: "thread_2", disposition: "repaired", rationale: "A reason" } ] }.to_json
    )

    expect(described_class.new.execute(agent_run_id: agent_run.id, thread_ids: [ "thread_1" ])).to include(authorized: false)
  end

  it "fails closed when agent-harness verification fails" do
    allow(Llm::Request).to receive(:call).and_raise(AgentHarness::TimeoutError, "timed out")

    expect(described_class.new.execute(agent_run_id: agent_run.id, thread_ids: [ "thread_1" ])).to include(authorized: false)
  end
end
