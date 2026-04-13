# frozen_string_literal: true

require "rails_helper"

RSpec.describe Activities::CreateGithubIssueActivity do
  let(:activity) { described_class.new }
  let(:project) { create(:project) }
  let(:agent_run) do
    create(:agent_run, :with_custom_prompt, :with_git_context, :with_metrics,
      project: project, goal: "create_issue", custom_prompt: "Analyze the auth system")
  end
  let(:github_client) { instance_double(GithubClient) }
  let(:issue_response) do
    Struct.new(:html_url, :number, :id, :title, :body, :state, :user, :labels, :created_at, :updated_at).new(
      "https://github.com/owner/repo/issues/10",
      10,
      12345,
      "Agent analysis",
      "Issue body",
      "open",
      Struct.new(:login).new("paid-bot"),
      [],
      Time.current,
      Time.current
    )
  end

  before do
    # These callbacks render/broadcast UI updates and are not part of this activity's behavior.
    allow(agent_run).to receive(:broadcast_project_updates)
    allow(agent_run).to receive(:update_project_last_agent_run_at)

    allow(Llm::GenerateIssueTitle).to receive(:call).and_return(nil)
    allow(GithubClient).to receive(:new).and_return(github_client)
    allow(github_client).to receive(:create_issue).and_return(issue_response)
    allow(ProcessRunQueueJob).to receive(:perform_later)
  end

  describe "#execute" do
    def log_failed_issue_creation_attempt
      agent_run.log!("stderr", %(bash -lc 'curl -X POST "$GITHUB_API_URL/repos/owner/repo/issues"'))
      agent_run.log!("stderr", "HTTP/1.1 500 Internal Server Error")
      agent_run.log!("stderr", "ActiveRecord::PendingMigrationError")
    end

    def log_failed_issue_creation_attempt_in_stdout
      agent_run.log!("stdout", %(bash -lc 'curl -X POST "$GITHUB_API_URL/repos/owner/repo/issues"'))
      agent_run.log!("stdout", "HTTP/1.1 500 Internal Server Error")
      agent_run.log!("stdout", "ActiveRecord::PendingMigrationError")
    end

    def log_failed_issue_creation_attempt_across_streams(command_log_type:, failure_log_type:)
      agent_run.log!(command_log_type, %(bash -lc 'curl -X POST "$GITHUB_API_URL/repos/owner/repo/issues"'))
      agent_run.log!(failure_log_type, "HTTP/1.1 500 Internal Server Error")
      agent_run.log!(failure_log_type, "ActiveRecord::PendingMigrationError")
    end

    def log_failed_issue_creation_attempt_with_trailing_noise(log_type: "stderr")
      agent_run.log!(log_type, %(bash -lc 'curl -X POST "$GITHUB_API_URL/repos/owner/repo/issues"'))
      agent_run.log!(log_type, "HTTP/1.1 500 Internal Server Error")
      agent_run.log!(log_type, "ActiveRecord::PendingMigrationError")

      (described_class::ISSUE_CREATION_FAILURE_LOG_BATCH_SIZE + 5).times do |index|
        agent_run.log!(log_type, "non-matching trailing log line #{index}")
      end
    end

    def log_fragmented_failed_issue_creation_attempt
      agent_run.log!("stderr", %(bash -lc 'curl -X POST "$GITHUB_API_URL/repos/owner/))
      agent_run.log!("stderr", %(repo/issues"'\nHTTP/1.1 500 Internal Server Error\n))
      agent_run.log!("stderr", "ActiveRecord::PendingMigrationError\n")
    end

    def log_mid_token_fragmented_failed_issue_creation_attempt
      agent_run.log!("stderr", %(bash -lc 'cur))
      agent_run.log!("stderr", %(l -X POST "$GITHUB_API_URL/repos/owner/repo/issues"'\n))
      agent_run.log!("stderr", "HTTP/1.1 500 Internal Server Error\n")
      agent_run.log!("stderr", "ActiveRecord::PendingMigrationError\n")
    end

    def log_fragmented_failed_issue_creation_attempt_with_leading_text
      agent_run.log!("stderr", %(Attempting direct issue creation before fallback:\nbash -lc 'curl -X POST "$GITHUB_API_URL/repos/owner/))
      agent_run.log!("stderr", %(repo/issues"'\nHTTP/1.1 500 Internal Server Error\n))
      agent_run.log!("stderr", "ActiveRecord::PendingMigrationError\n")
    end

    def log_fragmented_failed_issue_creation_attempt_with_interleaved_failures
      agent_run.log!("stdout", %(bash -lc 'curl ))
      agent_run.log!("stderr", "HTTP/1.1 500 Internal Server Error")
      agent_run.log!("stderr", "ActiveRecord::PendingMigrationError")
      agent_run.log!("stdout", %(-X POST "$GITHUB_API_URL/repos/owner/repo/issues"'\n))
    end

    def log_failed_issue_creation_attempt_with_url_before_request_option
      agent_run.log!("stderr", %(bash -lc 'curl "$GITHUB_API_URL/repos/owner/repo/issues" -X POST'))
      agent_run.log!("stderr", "HTTP/1.1 500 Internal Server Error")
      agent_run.log!("stderr", "ActiveRecord::PendingMigrationError")
    end

    def log_failed_issue_comment_attempt
      agent_run.log!("stderr", %(curl -X POST "$GITHUB_API_URL/repos/owner/repo/issues/10/comments"))
      agent_run.log!("stderr", "HTTP/1.1 500 Internal Server Error")
      agent_run.log!("stderr", "Upstream request failed")
    end

    def log_failed_issue_label_attempt
      agent_run.log!("stderr", %(curl -X POST "$GITHUB_API_URL/repos/owner/repo/issues/10/labels"))
      agent_run.log!("stderr", "HTTP/1.1 502 Bad Gateway")
      agent_run.log!("stderr", "Upstream request failed")
    end

    it "creates a GitHub issue via the API" do
      expect(github_client).to receive(:create_issue).with(
        project.full_name,
        title: a_string_matching(/.+/),
        body: a_string_matching(/.+/),
        labels: [ "paid-generated" ]
      ).and_return(issue_response)

      result = activity.execute(agent_run_id: agent_run.id)

      expect(result[:issue_url]).to eq("https://github.com/owner/repo/issues/10")
      expect(result[:issue_number]).to eq(10)
    end

    it "marks the agent run as completed with issue details" do
      activity.execute(agent_run_id: agent_run.id)

      agent_run.reload
      expect(agent_run.status).to eq("completed")
      expect(agent_run.created_issue_url).to eq("https://github.com/owner/repo/issues/10")
      expect(agent_run.created_issue_number).to eq(10)
    end

    it "logs the issue creation to agent run" do
      activity.execute(agent_run_id: agent_run.id)

      log = agent_run.agent_run_logs.last
      expect(log.log_type).to eq("system")
      expect(log.content).to include("https://github.com/owner/repo/issues/10")
    end

    it "triggers ProcessRunQueueJob" do
      expect(ProcessRunQueueJob).to receive(:perform_later)

      activity.execute(agent_run_id: agent_run.id)
    end

    it "uses first markdown heading as title when agent output has one" do
      agent_run.log!("stdout", "# Authentication System Analysis\n\nThe auth system uses JWT tokens.")

      expect(github_client).to receive(:create_issue).with(
        anything,
        hash_including(title: "Authentication System Analysis")
      ).and_return(issue_response)

      activity.execute(agent_run_id: agent_run.id)
    end

    it "uses level-2 markdown heading as title" do
      agent_run.log!("stdout", "## Security Audit Results\n\nFindings listed below.")

      expect(github_client).to receive(:create_issue).with(
        anything,
        hash_including(title: "Security Audit Results")
      ).and_return(issue_response)

      activity.execute(agent_run_id: agent_run.id)
    end

    it "strips trailing markdown closing hashes from headings" do
      agent_run.log!("stdout", "## Security Audit Results ##\n\nFindings listed below.")

      expect(github_client).to receive(:create_issue).with(
        anything,
        hash_including(title: "Security Audit Results")
      ).and_return(issue_response)

      activity.execute(agent_run_id: agent_run.id)
    end

    it "falls back to LLM-generated title when no heading" do
      agent_run.log!("stdout", "The auth system uses JWT tokens.")
      allow(Llm::GenerateIssueTitle).to receive(:call).and_return("JWT authentication analysis")

      expect(github_client).to receive(:create_issue).with(
        anything,
        hash_including(title: "JWT authentication analysis")
      ).and_return(issue_response)

      activity.execute(agent_run_id: agent_run.id)
    end

    it "falls back to default title when LLM returns nil" do
      agent_run.log!("stdout", "The auth system uses JWT tokens.")
      allow(Llm::GenerateIssueTitle).to receive(:call).and_return(nil)

      expect(github_client).to receive(:create_issue).with(
        anything,
        hash_including(title: "Agent analysis")
      ).and_return(issue_response)

      activity.execute(agent_run_id: agent_run.id)
    end

    it "falls back to default title when no stdout output" do
      no_prompt_run = create(:agent_run, :with_git_context, project: project,
        goal: "create_issue", custom_prompt: "Do analysis")

      expect(github_client).to receive(:create_issue).with(
        anything,
        hash_including(title: "Agent analysis")
      ).and_return(issue_response)

      activity.execute(agent_run_id: no_prompt_run.id)
    end

    it "includes agent stdout in the issue body when available" do
      agent_run.log!("stdout", "Here is my analysis of the codebase.")

      expect(github_client).to receive(:create_issue).with(
        anything,
        hash_including(body: a_string_including("Here is my analysis"))
      ).and_return(issue_response)

      activity.execute(agent_run_id: agent_run.id)
    end

    it "falls back to stderr content when no stdout is available" do
      agent_run.log!("stderr", "# Drafted Issue Title\n\nHere is detailed analysis from stderr.")

      expect(github_client).to receive(:create_issue).with(
        anything,
        hash_including(
          title: "Drafted Issue Title",
          body: a_string_including("detailed analysis from stderr")
        )
      ).and_return(issue_response)

      activity.execute(agent_run_id: agent_run.id)
    end

    it "prefers stdout over stderr when both are available" do
      agent_run.log!("stdout", "# Stdout Title\n\nStdout content.")
      agent_run.log!("stderr", "# Stderr Title\n\nStderr content.")

      expect(github_client).to receive(:create_issue).with(
        anything,
        hash_including(
          title: "Stdout Title",
          body: a_string_including("Stdout content")
        )
      ).and_return(issue_response)

      activity.execute(agent_run_id: agent_run.id)
    end

    it "uses fallback body when no stdout or stderr is available" do
      expect(github_client).to receive(:create_issue).with(
        anything,
        hash_including(body: a_string_including("automatically generated by"))
      ).and_return(issue_response)

      activity.execute(agent_run_id: agent_run.id)
    end

    it "syncs the created issue to the local database" do
      expect {
        activity.execute(agent_run_id: agent_run.id)
      }.to change(Issue, :count).by(1)

      synced = project.issues.find_by(github_issue_id: 12345)
      expect(synced).to be_present
      expect(synced.github_number).to eq(10)
    end

    it "refuses to create a fallback issue from issue-creation failure output" do
      log_failed_issue_creation_attempt

      expect(github_client).not_to receive(:create_issue)

      expect {
        activity.execute(agent_run_id: agent_run.id)
      }.to raise_error(Temporalio::Error::ApplicationError) { |error|
        expect(error.type).to eq("IssueDraftInvalid")
      }

      expect(agent_run.reload.status).not_to eq("completed")
      expect(agent_run.created_issue_url).to be_nil
      expect(agent_run.created_issue_number).to be_nil
      expect(agent_run.agent_run_logs.last.content)
        .to include("Refused fallback issue creation")
    end

    it "refuses to create a fallback issue from stdout issue-creation failure output" do
      log_failed_issue_creation_attempt_in_stdout

      expect(github_client).not_to receive(:create_issue)

      expect {
        activity.execute(agent_run_id: agent_run.id)
      }.to raise_error(Temporalio::Error::ApplicationError) { |error|
        expect(error.type).to eq("IssueDraftInvalid")
      }
    end

    it "refuses fallback issue creation when the command is in stdout and the failure markers are in stderr" do
      log_failed_issue_creation_attempt_across_streams(command_log_type: "stdout", failure_log_type: "stderr")

      expect(github_client).not_to receive(:create_issue)

      expect {
        activity.execute(agent_run_id: agent_run.id)
      }.to raise_error(Temporalio::Error::ApplicationError) { |error|
        expect(error.type).to eq("IssueDraftInvalid")
      }
    end

    it "refuses fallback issue creation when the command is in stderr and the failure markers are in stdout" do
      log_failed_issue_creation_attempt_across_streams(command_log_type: "stderr", failure_log_type: "stdout")

      expect(github_client).not_to receive(:create_issue)

      expect {
        activity.execute(agent_run_id: agent_run.id)
      }.to raise_error(Temporalio::Error::ApplicationError) { |error|
        expect(error.type).to eq("IssueDraftInvalid")
      }
    end

    it "refuses fallback issue creation when the stderr command is split across log rows" do
      log_fragmented_failed_issue_creation_attempt

      expect(github_client).not_to receive(:create_issue)

      expect {
        activity.execute(agent_run_id: agent_run.id)
      }.to raise_error(Temporalio::Error::ApplicationError) { |error|
        expect(error.type).to eq("IssueDraftInvalid")
      }
    end

    it "refuses fallback issue creation when the stderr command splits the curl token across log rows" do
      log_mid_token_fragmented_failed_issue_creation_attempt

      expect(github_client).not_to receive(:create_issue)

      expect {
        activity.execute(agent_run_id: agent_run.id)
      }.to raise_error(Temporalio::Error::ApplicationError) { |error|
        expect(error.type).to eq("IssueDraftInvalid")
      }
    end

    it "refuses fallback issue creation when a multi-line stderr chunk prefixes a split command" do
      log_fragmented_failed_issue_creation_attempt_with_leading_text

      expect(github_client).not_to receive(:create_issue)

      expect {
        activity.execute(agent_run_id: agent_run.id)
      }.to raise_error(Temporalio::Error::ApplicationError) { |error|
        expect(error.type).to eq("IssueDraftInvalid")
      }
    end

    it "refuses fallback issue creation when failure lines interleave a fragmented command" do
      log_fragmented_failed_issue_creation_attempt_with_interleaved_failures

      expect(github_client).not_to receive(:create_issue)

      expect {
        activity.execute(agent_run_id: agent_run.id)
      }.to raise_error(Temporalio::Error::ApplicationError) { |error|
        expect(error.type).to eq("IssueDraftInvalid")
      }
    end

    it "refuses fallback issue creation even when the failed direct create attempt is older than 200 later log rows" do
      log_failed_issue_creation_attempt_with_trailing_noise

      expect(github_client).not_to receive(:create_issue)

      expect {
        activity.execute(agent_run_id: agent_run.id)
      }.to raise_error(Temporalio::Error::ApplicationError) { |error|
        expect(error.type).to eq("IssueDraftInvalid")
      }
    end

    it "refuses fallback issue creation when curl lists the issues URL before -X POST" do
      log_failed_issue_creation_attempt_with_url_before_request_option

      expect(github_client).not_to receive(:create_issue)

      expect {
        activity.execute(agent_run_id: agent_run.id)
      }.to raise_error(Temporalio::Error::ApplicationError) { |error|
        expect(error.type).to eq("IssueDraftInvalid")
      }
    end

    it "still creates a valid issue whose content mentions pending migrations" do
      agent_run.log!("stdout", <<~TEXT)
        # Proxy write path crashes with PendingMigrationError

        Creating an issue through the proxy can fail with `ActiveRecord::PendingMigrationError`.
      TEXT

      expect(github_client).to receive(:create_issue).with(
        anything,
        hash_including(
          title: "Proxy write path crashes with PendingMigrationError",
          body: a_string_including("ActiveRecord::PendingMigrationError")
        )
      ).and_return(issue_response)

      activity.execute(agent_run_id: agent_run.id)
    end

    it "still creates a valid issue that describes the issues endpoint returning 500" do
      agent_run.log!("stdout", <<~TEXT)
        # Proxy issue creation fails with 500s

        When POST to /repos/acme/app/issues returns 500 Internal Server Error, the
        fallback issue should still be published so the incident can be tracked.
      TEXT

      expect(github_client).to receive(:create_issue).with(
        anything,
        hash_including(
          title: "Proxy issue creation fails with 500s",
          body: a_string_including("POST to /repos/acme/app/issues returns 500 Internal Server Error")
        )
      ).and_return(issue_response)

      activity.execute(agent_run_id: agent_run.id)
    end

    it "still creates a fallback issue when only issue comment creation failed" do
      log_failed_issue_comment_attempt

      expect(github_client).to receive(:create_issue).and_return(issue_response)

      activity.execute(agent_run_id: agent_run.id)
    end

    it "still creates a fallback issue when only issue label creation failed" do
      log_failed_issue_label_attempt

      expect(github_client).to receive(:create_issue).and_return(issue_response)

      activity.execute(agent_run_id: agent_run.id)
    end

    it "still creates a valid issue that includes a curl reproduction snippet and 500 text" do
      agent_run.log!("stdout", <<~TEXT)
        # Proxy issue creation needs a fallback

        Reproduction:
        ```sh
        curl -X POST "$GITHUB_API_URL/repos/acme/app/issues"
        ```

        The request currently returns 500 Internal Server Error, so the fallback
        path should still publish this issue draft.
      TEXT

      expect(github_client).to receive(:create_issue).with(
        anything,
        hash_including(
          title: "Proxy issue creation needs a fallback",
          body: a_string_including(%(curl -X POST "$GITHUB_API_URL/repos/acme/app/issues"))
        )
      ).and_return(issue_response)

      activity.execute(agent_run_id: agent_run.id)
    end

    it "still creates a valid issue that includes an unfenced prompt-prefixed curl reproduction line" do
      agent_run.log!("stdout", <<~TEXT)
        # Proxy issue creation needs a fallback

        Reproduction:
        $ curl -X POST "$GITHUB_API_URL/repos/acme/app/issues"

        The request currently returns 500 Internal Server Error, so the fallback
        path should still publish this issue draft.
      TEXT

      expect(github_client).to receive(:create_issue).with(
        anything,
        hash_including(
          title: "Proxy issue creation needs a fallback",
          body: a_string_including(%($ curl -X POST "$GITHUB_API_URL/repos/acme/app/issues"))
        )
      ).and_return(issue_response)

      activity.execute(agent_run_id: agent_run.id)
    end

    it "still creates a valid stderr fallback draft that includes a curl reproduction snippet and 500 text" do
      agent_run.log!("stderr", <<~TEXT)
        # Proxy issue creation needs a fallback

        Reproduction:
        ```sh
        curl -X POST "$GITHUB_API_URL/repos/acme/app/issues"
        ```

        The request currently returns 500 Internal Server Error, so the fallback
        path should still publish this issue draft.
      TEXT

      expect(github_client).to receive(:create_issue).with(
        anything,
        hash_including(
          title: "Proxy issue creation needs a fallback",
          body: a_string_including(%(curl -X POST "$GITHUB_API_URL/repos/acme/app/issues"))
        )
      ).and_return(issue_response)

      activity.execute(agent_run_id: agent_run.id)
    end

    it "still creates a valid stderr fallback draft when a fenced curl snippet is split across log rows" do
      agent_run.log!("stderr", "# Proxy issue creation needs a fallback\n\nReproduction:\n```sh\n")
      agent_run.log!("stderr", %(curl -X POST "$GITHUB_API_URL/repos/acme/))
      agent_run.log!("stderr", %(app/issues"\n```\n\nThe request returns 500 Internal Server Error.\n))

      expect(github_client).to receive(:create_issue).with(
        anything,
        hash_including(
          title: "Proxy issue creation needs a fallback",
          body: a_string_including(%(curl -X POST "$GITHUB_API_URL/repos/acme/))
        )
      ).and_return(issue_response)

      activity.execute(agent_run_id: agent_run.id)
    end

    it "still creates a valid stderr fallback draft with an unfenced curl reproduction line" do
      agent_run.log!("stderr", <<~TEXT)
        # Proxy issue creation needs a fallback

        Reproduction:
        curl -X POST "$GITHUB_API_URL/repos/acme/app/issues"

        The request currently returns 500 Internal Server Error, so the fallback
        path should still publish this issue draft.
      TEXT

      expect(github_client).to receive(:create_issue).with(
        anything,
        hash_including(
          title: "Proxy issue creation needs a fallback",
          body: a_string_including(%(curl -X POST "$GITHUB_API_URL/repos/acme/app/issues"))
        )
      ).and_return(issue_response)

      activity.execute(agent_run_id: agent_run.id)
    end

    it "still creates a valid stderr fallback draft when a split code fence wraps a prompt-prefixed curl snippet" do
      agent_run.log!("stderr", "# Proxy issue creation needs a fallback\n\nReproduction:\n``")
      agent_run.log!("stderr", %(`sh\n$ curl -X POST "$GITHUB_API_URL/repos/acme/app/issues"\n))
      agent_run.log!("stderr", "```\n\nThe request currently returns 500 Internal Server Error.\n")

      expect(github_client).to receive(:create_issue).with(
        anything,
        hash_including(
          title: "Proxy issue creation needs a fallback",
          body: a_string_including(%($ curl -X POST "$GITHUB_API_URL/repos/acme/app/issues"))
        )
      ).and_return(issue_response)

      activity.execute(agent_run_id: agent_run.id)
    end

    it "still creates a valid stderr fallback draft that describes a curl reproduction in prose" do
      agent_run.log!("stderr", <<~TEXT)
        # Proxy issue creation needs a fallback

        To reproduce, run curl -X POST "$GITHUB_API_URL/repos/acme/app/issues"
        and observe that the proxy returns 500 Internal Server Error.
      TEXT

      expect(github_client).to receive(:create_issue).with(
        anything,
        hash_including(
          title: "Proxy issue creation needs a fallback",
          body: a_string_including(%(run curl -X POST "$GITHUB_API_URL/repos/acme/app/issues"))
        )
      ).and_return(issue_response)

      activity.execute(agent_run_id: agent_run.id)
    end

    context "when auto_add_labels_enabled is false" do
      before { project.update!(auto_add_labels_enabled: false) }

      it "creates the issue with an empty labels array" do
        expect(github_client).to receive(:create_issue).with(
          project.full_name,
          hash_including(labels: [])
        ).and_return(issue_response)

        activity.execute(agent_run_id: agent_run.id)
      end
    end

    context "when auto_add_labels_enabled is true with a custom generated label" do
      before { project.update!(auto_add_labels_enabled: true, generated_label_name: "my-label") }

      it "creates the issue with the custom label" do
        expect(github_client).to receive(:create_issue).with(
          project.full_name,
          hash_including(labels: [ "my-label" ])
        ).and_return(issue_response)

        activity.execute(agent_run_id: agent_run.id)
      end
    end

    it "raises ActiveRecord::RecordNotFound for invalid agent_run_id" do
      expect {
        activity.execute(agent_run_id: -1)
      }.to raise_error(ActiveRecord::RecordNotFound)
    end
  end
end
