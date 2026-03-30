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
        body: a_string_including("Agent Run Diagnosis")
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

    context "when error message contains secrets" do
      let(:agent_run) do
        create(:agent_run, :failed, project: project,
          error_message: "Connection failed: API_KEY=sk_live_abcdef1234567890 host unreachable")
      end

      it "redacts secrets before sending to the LLM" do
        described_class.call(agent_run: agent_run)

        expect(AgentHarness).to have_received(:send_message).with(
          a_string_including("API_KEY=[REDACTED]").and(satisfy { |s| !s.include?("sk_live_abcdef1234567890") }),
          provider: :claude,
          model: "claude-sonnet-4-6",
          timeout: 60
        )
      end

      it "redacts secrets in the GitHub issue body" do
        described_class.call(agent_run: agent_run)

        expect(github_client).to have_received(:create_issue).with(
          project.full_name,
          title: anything,
          body: a_string_including("API_KEY=[REDACTED]").and(satisfy { |s| !s.include?("sk_live_abcdef1234567890") })
        )
      end
    end

    context "when issue title contains secrets" do
      let(:issue) { create(:issue, project: project, title: "Fix API_KEY=sk_live_secret123 leak") }
      let(:agent_run) { create(:agent_run, :failed, project: project, issue: issue) }

      it "redacts secrets in the issue title sent to the LLM" do
        described_class.call(agent_run: agent_run)

        expect(AgentHarness).to have_received(:send_message).with(
          a_string_including("API_KEY=[REDACTED]").and(satisfy { |s| !s.include?("sk_live_secret123") }),
          provider: :claude,
          model: "claude-sonnet-4-6",
          timeout: 60
        )
      end

      it "redacts secrets in the GitHub issue title" do
        described_class.call(agent_run: agent_run)

        expect(github_client).to have_received(:create_issue).with(
          project.full_name,
          title: a_string_including("API_KEY=[REDACTED]").and(satisfy { |s| !s.include?("sk_live_secret123") }),
          body: anything
        )
      end
    end

    context "when custom_prompt contains secrets" do
      let(:agent_run) do
        create(:agent_run, :failed, project: project, issue: nil,
          custom_prompt: "Deploy with TOKEN=ghp_abc123secret to staging")
      end

      it "redacts secrets in the custom_prompt before sending to the LLM" do
        described_class.call(agent_run: agent_run)

        expect(AgentHarness).to have_received(:send_message).with(
          a_string_including("TOKEN=[REDACTED]").and(satisfy { |s| !s.include?("ghp_abc123secret") }),
          provider: :claude,
          model: "claude-sonnet-4-6",
          timeout: 60
        )
      end
    end

    context "when LLM diagnosis echoes secrets" do
      let(:llm_response) do
        AgentHarness::Response.new(
          output: "The error occurred because API_KEY=sk_live_leaked was invalid.",
          exit_code: 0,
          duration: 5.0,
          provider: :claude,
          model: "claude-sonnet-4-6",
          tokens: { input: 500, output: 200, total: 700 }
        )
      end

      it "redacts secrets in the diagnosis before creating GitHub issue" do
        described_class.call(agent_run: agent_run)

        expect(github_client).to have_received(:create_issue).with(
          project.full_name,
          title: anything,
          body: a_string_including("API_KEY=[REDACTED]").and(satisfy { |s| !s.include?("sk_live_leaked") })
        )
      end
    end

    context "when error message contains standalone GitHub tokens" do
      let(:agent_run) do
        create(:agent_run, :failed, project: project,
          error_message: "Auth failed with ghp_aBcDeFgHiJkLmNoPqRsTuVwXyZ0123456789")
      end

      it "redacts standalone GitHub tokens before sending to the LLM" do
        described_class.call(agent_run: agent_run)

        expect(AgentHarness).to have_received(:send_message).with(
          satisfy { |s| !s.include?("ghp_aBcDeFgHiJkLmNoPqRsTuVwXyZ0123456789") },
          provider: :claude,
          model: "claude-sonnet-4-6",
          timeout: 60
        )
      end

      it "redacts standalone GitHub tokens in the GitHub issue body" do
        described_class.call(agent_run: agent_run)

        expect(github_client).to have_received(:create_issue).with(
          project.full_name,
          title: anything,
          body: satisfy { |s| !s.include?("ghp_aBcDeFgHiJkLmNoPqRsTuVwXyZ0123456789") }
        )
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
