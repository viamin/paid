# frozen_string_literal: true

require "rails_helper"

RSpec.describe AgentRuns::DiagnoseError do
  let(:account) { create(:account) }
  let(:github_token) { create(:github_token, account: account) }
  let(:project) { create(:project, account: account, github_token: github_token) }
  let(:agent_run) { create(:agent_run, :failed, project: project) }

  let(:github_client) { instance_double(GithubClient) }
  let(:gh_issue) { double(html_url: "https://github.com/example/repo/issues/99") }

  let(:llm_response) do
    AgentHarness::Response.new(
      output: "## Root Cause\nThe agent failed due to a timeout.\n\n## Suggested Fix\nIncrease timeout.",
      exit_code: 0,
      duration: 5.0,
      provider: :claude,
      model: "claude-sonnet-4-6",
      tokens: { input: 500, output: 200, total: 700 }
    )
  end

  before do
    allow(github_token).to receive(:client).and_return(github_client)
    allow(AgentHarness).to receive(:send_message).and_return(llm_response)
    allow(github_client).to receive(:create_issue).and_return(gh_issue)
  end

  describe ".call" do
    it "returns a successful result with issue URL" do
      result = described_class.call(agent_run: agent_run)

      expect(result).to be_success
      expect(result.issue_url).to eq("https://github.com/example/repo/issues/99")
    end

    it "calls AgentHarness to analyze the error" do
      described_class.call(agent_run: agent_run)

      expect(AgentHarness).to have_received(:send_message).with(
        a_string_including("diagnosing a failed agent run"),
        provider: :claude,
        model: "claude-sonnet-4-6",
        timeout: 60
      )
    end

    it "creates a GitHub issue with the diagnosis" do
      described_class.call(agent_run: agent_run)

      expect(github_client).to have_received(:create_issue).with(
        project.full_name,
        title: a_string_including("Diagnosis: Agent Run ##{agent_run.id}"),
        body: a_string_including("Agent Run Diagnosis"),
        labels: [ "diagnosis" ]
      )
    end

    it "logs the diagnosis issue creation" do
      described_class.call(agent_run: agent_run)

      log = agent_run.agent_run_logs.find_by(log_type: "system")
      expect(log.content).to include("Diagnosis issue created")
    end

    context "when the LLM returns no output" do
      let(:llm_response) do
        AgentHarness::Response.new(
          output: "",
          exit_code: 1,
          duration: 5.0,
          provider: :claude,
          model: "claude-sonnet-4-6",
          tokens: nil
        )
      end

      it "returns a failure result" do
        result = described_class.call(agent_run: agent_run)

        expect(result).to be_failure
        expect(result.message).to include("No diagnosis")
      end

      it "does not create a GitHub issue" do
        described_class.call(agent_run: agent_run)

        expect(github_client).not_to have_received(:create_issue)
      end
    end

    context "when the agent run has no error message" do
      let(:agent_run) { create(:agent_run, :completed, project: project) }

      it "raises an ArgumentError" do
        expect {
          described_class.call(agent_run: agent_run)
        }.to raise_error(ArgumentError, /no error message/)
      end
    end

    context "when AgentHarness raises an error" do
      before do
        allow(AgentHarness).to receive(:send_message)
          .and_raise(AgentHarness::Error.new("LLM unavailable"))
      end

      it "returns a failure result" do
        result = described_class.call(agent_run: agent_run)

        expect(result).to be_failure
        expect(result.message).to include("LLM unavailable")
      end
    end

    context "when GitHub issue creation fails" do
      before do
        allow(github_client).to receive(:create_issue)
          .and_raise(GithubClient::Error.new("API rate limited"))
      end

      it "returns a failure result" do
        result = described_class.call(agent_run: agent_run)

        expect(result).to be_failure
        expect(result.message).to include("API rate limited")
      end
    end
  end
end
