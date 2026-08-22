# frozen_string_literal: true

require "rails_helper"
require "ostruct"

# @spec LID-RUNS-003
RSpec.describe Activities::CreatePullRequestActivity do
  fixture "activities/create_pull_request/base"

  let(:activity) { described_class.new }
  let(:fixture_repository) { instance_variable_get(:@_fixture_kit_repository) }
  let(:project) { fixture_repository.project }
  let(:issue) { fixture_repository.issue }
  let(:agent_run) { fixture_repository.agent_run }
  let(:github_client) { instance_double(GithubClient) }
  let(:pr_response) { Struct.new(:html_url, :number, :body, :title).new("https://github.com/owner/repo/pull/42", 42, "PR body", "PR title") }
  let(:issue_response) do
    OpenStruct.new(
      id: 4242,
      number: 42,
      title: "PR title",
      body: "PR body",
      state: "open",
      labels: [],
      pull_request: OpenStruct.new(html_url: "https://github.com/owner/repo/pull/42"),
      user: OpenStruct.new(login: "viamin"),
      created_at: Time.zone.parse("2026-04-14 00:00:00 UTC"),
      updated_at: Time.zone.parse("2026-04-14 00:01:00 UTC")
    )
  end

  # Returns a docs-only file set that satisfies the adoption output contract,
  # using +instruction_file+ (AGENTS.md / CLAUDE.md / copilot-instructions.md).
  def full_adoption_files(instruction_file = "AGENTS.md")
    [
      "docs/high-level-design.md",
      "docs/intent/auth/auth-design.md",
      "docs/intent/auth/auth-specs.md",
      "docs/arrows/index.yaml",
      instruction_file
    ]
  end

  before do
    allow(GithubClient).to receive(:new).and_return(github_client)
    allow(github_client).to receive_messages(
      pull_requests: [],
      create_pull_request: pr_response,
      issue: issue_response,
      ref: instance_double(Sawyer::Resource),
      compare_changed_files: []
    )
    allow(github_client).to receive(:add_labels_to_issue)
    allow(github_client).to receive(:update_pull_request)
    # Stub external agent harness so Llm::GeneratePrDescription runs without real external calls.
    # By default, return a failed response so the activity falls back to a deterministic description.
    allow(AgentHarness).to receive(:send_message)
      .and_return(instance_double(AgentHarness::Response, success?: false, output: "", error: nil))
    allow_any_instance_of(Llm::GeneratePrDescription).to receive(:sleep) # rubocop:disable RSpec/AnyInstance
  end

  describe "#execute" do
    it "creates a pull request via the GitHub API" do
      issue.update!(title: "Resolve auth redirect bug")

      expect(github_client).to receive(:create_pull_request).with(
        project.full_name,
        base: project.default_branch,
        head: agent_run.branch_name,
        title: "fix: Resolve auth redirect bug",
        body: a_string_including("Closes ##{issue.github_number}"),
        draft: true
      ).and_return(pr_response)

      result = activity.execute(agent_run_id: agent_run.id)

      expect(result[:pull_request_url]).to eq("https://github.com/owner/repo/pull/42")
      expect(result[:pull_request_number]).to eq(42)
    end

    it "preserves conventional commit issue titles in the PR title" do
      issue.update!(title: "feat(quality): automatic pause on quality threshold breach")

      activity.execute(agent_run_id: agent_run.id)

      expect(github_client).to have_received(:create_pull_request).with(
        anything,
        hash_including(title: "feat(quality): automatic pause on quality threshold breach")
      )
    end

    it "normalizes the conventional commit type to lowercase in PR titles" do
      issue.update!(title: "Feat(quality): automatic pause on quality threshold breach")

      activity.execute(agent_run_id: agent_run.id)

      expect(github_client).to have_received(:create_pull_request).with(
        anything,
        hash_including(title: "feat(quality): automatic pause on quality threshold breach")
      )
    end

    it "infers conventional commit titles from plain-English feature issues" do
      issue.update!(title: "Add queue monitoring dashboard")

      activity.execute(agent_run_id: agent_run.id)

      expect(github_client).to have_received(:create_pull_request).with(
        anything,
        hash_including(title: "feat: Add queue monitoring dashboard")
      )
    end

    it "uses a plain PR title when the project overrides PR title style away from conventional commits" do
      create(:project_convention_override,
        project: project,
        key: "pr_title_style",
        value: { "type" => "plain", "fallback_subject" => "Apply Paid changes" })
      issue.update!(title: "Queue monitoring dashboard")

      activity.execute(agent_run_id: agent_run.id)

      expect(github_client).to have_received(:create_pull_request).with(
        anything,
        hash_including(title: "Queue monitoring dashboard")
      )
    end

    it "falls back to feat for ambiguous issue titles instead of under-versioning them as fixes" do
      issue.update!(title: "Worker pool tuning")

      activity.execute(agent_run_id: agent_run.id)

      expect(github_client).to have_received(:create_pull_request).with(
        anything,
        hash_including(title: "feat: Worker pool tuning")
      )
    end

    it "enforces allowed PR title types for release-sensitive repos" do
      create(:project_convention_override,
        project: project,
        key: "pr_title_style",
        value: {
          "type" => "conventional_commits",
          "required" => true,
          "default_type" => "feat",
          "allowed_types" => %w[feat fix],
          "significant_for_release" => true
        })
      issue.update!(title: "docs: Update release notes")

      activity.execute(agent_run_id: agent_run.id)

      expect(github_client).to have_received(:create_pull_request).with(
        anything,
        hash_including(title: "feat: Update release notes")
      )
    end

    it "checks for an existing PR before creating a new one" do
      activity.execute(agent_run_id: agent_run.id)

      expect(github_client).to have_received(:pull_requests).with(
        project.full_name,
        head: "#{project.owner}:#{agent_run.branch_name}",
        state: "open"
      )
    end

    it "adds paid-tests-ready-for-review on test-writing runs" do # @spec TDD-PR-001
      agent_run.update!(
        tdd_phase: "test_writing",
        base_commit_sha: "def123def456789012345678901234567890abcd",
        result_commit_sha: "abc123def456789012345678901234567890abcd"
      )
      allow(github_client).to receive(:compare_changed_files).and_return([ "spec/models/widget_spec.rb" ])

      activity.execute(agent_run_id: agent_run.id)

      expect(github_client).to have_received(:add_labels_to_issue).with(
        project.full_name, 42, include("paid-tests-ready-for-review")
      )
    end

    it "marks the agent run as completed with PR details" do
      activity.execute(agent_run_id: agent_run.id)

      agent_run.reload
      expect(agent_run.status).to eq("completed")
      expect(agent_run.pull_request_url).to eq("https://github.com/owner/repo/pull/42")
      expect(agent_run.pull_request_number).to eq(42)
    end

    it "does not create a pull request for cancelled runs" do
      agent_run = create(:agent_run, :cancelled, :with_git_context, project: project, issue: issue)

      result = activity.execute(agent_run_id: agent_run.id)

      expect(github_client).not_to have_received(:create_pull_request)
      expect(result[:agent_run_id]).to eq(agent_run.id)
      expect(result[:skipped]).to be true
      expect(result[:cancelled]).to be true
      expect(agent_run.reload.status).to eq("cancelled")
    end

    it "surfaces failed LID coherence findings in the PR body" do
      set_coherence_failure(summary_line: "Coherence soft-block: 1 reverse orphan, 2 untagged test files.")

      captured_body = capture_pr_body

      expect(captured_body).to include("## LID Coherence Soft-Block")
      expect(captured_body).to include("Coherence soft-block: 1 reverse orphan, 2 untagged test files.")
    end

    it "appends coherence section even when template omits {{quality_warnings}}" do
      PrTemplate.create!(
        account: project.account, project: project, name: "no-warnings",
        body: "## Summary\n\n{{description}}", pr_type: "default", position: 0, enabled: true
      )
      set_coherence_failure(summary_line: "Coherence soft-block: missing @spec annotations.")

      captured_body = capture_pr_body

      expect(captured_body).to include("## LID Coherence Soft-Block")
      expect(captured_body).to include("Coherence soft-block: missing @spec annotations.")
    end

    it "syncs a local pull request row immediately after PR creation" do
      expect {
        activity.execute(agent_run_id: agent_run.id)
      }.to change { project.issues.pull_requests_only.where(github_number: 42).count }.by(1)

      pull_request = project.issues.pull_requests_only.find_by!(github_number: 42)
      expect(pull_request.github_issue_id).to eq(4242)
      expect(pull_request.labels).to include("paid-generated", "paid-automation")
    end

    it "reconciles a created pull request when cancellation wins the completion lock" do
      allow(github_client).to receive(:create_pull_request) do
        agent_run.cancel!
        pr_response
      end

      expect {
        result = activity.execute(agent_run_id: agent_run.id)

        expect(result[:pull_request_url]).to eq("https://github.com/owner/repo/pull/42")
        expect(result[:pull_request_number]).to eq(42)
      }.to change { project.issues.pull_requests_only.where(github_number: 42).count }.by(1)

      agent_run.reload
      expect(agent_run.status).to eq("cancelled")
      expect(agent_run.pull_request_url).to be_nil
      expect(github_client).to have_received(:add_labels_to_issue).with(
        project.full_name, 42, [ "paid-generated", "paid-automation" ]
      )
    end

    it "adds the generated and automation labels to the PR" do
      expect(github_client).to receive(:add_labels_to_issue).with(
        project.full_name, 42, [ "paid-generated", "paid-automation" ]
      )

      activity.execute(agent_run_id: agent_run.id)
    end

    it "logs the PR creation to agent run" do
      activity.execute(agent_run_id: agent_run.id)

      log = agent_run.agent_run_logs.last
      expect(log.log_type).to eq("system")
      expect(log.content).to include("PR created:")
      expect(log.content).to include("https://github.com/owner/repo/pull/42")
    end

    it "uses deterministic fallback body when LLM description is nil" do
      agent_run.log!("stdout", "Here are the changes I made to fix the issue.")

      captured_body = nil
      allow(github_client).to receive(:create_pull_request) do |*_args, **kwargs|
        captured_body = kwargs[:body]
        pr_response
      end

      activity.execute(agent_run_id: agent_run.id)

      expect(captured_body).to include("## Summary")
      expect(captured_body).to include(issue.title)
      expect(captured_body).to include("Closes ##{issue.github_number}")
      expect(captured_body).not_to include("Here are the changes I made to fix the issue.")
    end

    it "appends a LID phase report when the project declares lid_mode" do
      allow(AgentRun).to receive(:find).with(agent_run.id).and_return(agent_run)
      project.update!(lid_mode: "full")
      agent_run.log!("stdout", "Added regression coverage with @#{'spec'} LID-RUN-001")
      agent_run.log!("stdout", "bin/coherence-check.mjs completed with 0 failures")

      captured_body = nil
      allow(github_client).to receive(:create_pull_request) do |*_args, **kwargs|
        captured_body = kwargs[:body]
        pr_response
      end

      activity.execute(agent_run_id: agent_run.id)

      expect(captured_body).to include("## LID Phase Report")
      expect(captured_body).to include("Mode: `full`")
      expect(captured_body).to include("LID-RUN-001")
      expect(captured_body).to include("Reported success in agent output")
    end

    it "reports coherence-check results from the newest captured agent output" do
      allow(AgentRun).to receive(:find).with(agent_run.id).and_return(agent_run)
      project.update!(lid_mode: "full")

      205.times { |index| agent_run.log!("stdout", "older output line #{index}") }
      agent_run.log!("stdout", "bin/coherence-check.mjs completed with 0 failures")

      captured_body = nil
      allow(github_client).to receive(:create_pull_request) do |*_args, **kwargs|
        captured_body = kwargs[:body]
        pr_response
      end

      activity.execute(agent_run_id: agent_run.id)

      expect(captured_body).to include("Reported success in agent output")
    end

    it "reports coherence-check results even when later logs push them beyond the 200-line tail" do
      allow(AgentRun).to receive(:find).with(agent_run.id).and_return(agent_run)
      project.update!(lid_mode: "full")
      agent_run.log!("stdout", "bin/coherence-check.mjs completed with 0 failures")
      205.times { |index| agent_run.log!("stdout", "later output line #{index}") }

      captured_body = nil
      allow(github_client).to receive(:create_pull_request) do |*_args, **kwargs|
        captured_body = kwargs[:body]
        pr_response
      end

      activity.execute(agent_run_id: agent_run.id)

      expect(captured_body).to include("Reported success in agent output")
    end

    it "does not treat unrelated later output as coherence-check success" do
      allow(AgentRun).to receive(:find).with(agent_run.id).and_return(agent_run)
      project.update!(lid_mode: "full")
      agent_run.log!("stdout", "bin/coherence-check.mjs started")
      agent_run.log!("stdout", "RSpec finished with 0 failures")

      captured_body = nil
      allow(github_client).to receive(:create_pull_request) do |*_args, **kwargs|
        captured_body = kwargs[:body]
        pr_response
      end

      activity.execute(agent_run_id: agent_run.id)

      expect(captured_body).to include("Referenced in agent output; inspect the run logs for the full result.")
    end

    it "treats ephemeral PR tests as test-first evidence in the LID report" do
      allow(AgentRun).to receive(:find).with(agent_run.id).and_return(agent_run)
      project.update!(lid_mode: "full")
      agent_run.update!(
        base_commit_sha: "def123def456789012345678901234567890abcd",
        result_commit_sha: "abc123def456789012345678901234567890abcd",
        worktree_path: Rails.root.to_s
      )
      allow(Open3).to receive(:capture2).and_return([
        ".ephemeral-tests/lid_report_spec.rb\n",
        instance_double(Process::Status, success?: true)
      ])

      captured_body = nil
      allow(github_client).to receive(:create_pull_request) do |*_args, **kwargs|
        captured_body = kwargs[:body]
        pr_response
      end

      activity.execute(agent_run_id: agent_run.id)

      expect(captured_body).to include("Changed test files: .ephemeral-tests/lid_report_spec.rb.")
    end

    it "does not use raw JSON as fallback body" do
      agent_run.log!("stdout", '{"type":"result","result":"","is_error":false}')

      captured_body = nil
      allow(github_client).to receive(:create_pull_request) do |*_args, **kwargs|
        captured_body = kwargs[:body]
        pr_response
      end

      activity.execute(agent_run_id: agent_run.id)

      expect(captured_body).to include(issue.title)
      expect(captured_body).to include("See ##{issue.github_number} for context")
      expect(captured_body).not_to include('{"type"')
    end

    it "does not use agent error messages as fallback body" do
      agent_run.log!("stdout", "Agent encountered an error: Rate limit exceeded")

      captured_body = nil
      allow(github_client).to receive(:create_pull_request) do |*_args, **kwargs|
        captured_body = kwargs[:body]
        pr_response
      end

      activity.execute(agent_run_id: agent_run.id)

      expect(captured_body).to include(issue.title)
      expect(captured_body).not_to include("Agent encountered an error")
    end

    it "does not record a PR description metric when the fallback body is used" do
      agent_run.log!("stdout", "Here are the changes I made to fix the issue.")

      expect {
        activity.execute(agent_run_id: agent_run.id)
      }.not_to change(LlmOutputMetric, :count)
    end

    it "uses templated fallback when no stdout is available" do
      expect(github_client).to receive(:create_pull_request).with(
        anything,
        hash_including(
          body: a_string_including("## Summary")
            .and(including(issue.title))
            .and(including("See ##{issue.github_number} for context"))
            .and(including("Closes ##{issue.github_number}"))
        )
      ).and_return(pr_response)

      activity.execute(agent_run_id: agent_run.id)
    end

    it "appends warn-only pre-commit findings to the PR body" do
      agent_run.log!(
        "system",
        "Pre-commit check 'mutant' failed",
        metadata: {
          event: "pre_commit_check",
          passed: false,
          failure_behavior: "warn",
          output_preview: "app/models/foo.rb:42 Surviving mutation in Foo#bar"
        }
      )

      expect(github_client).to receive(:create_pull_request).with(
        anything,
        hash_including(
          body: a_string_including("## Quality Warnings")
            .and(including("Surviving mutation in Foo#bar"))
        )
      ).and_return(pr_response)

      activity.execute(agent_run_id: agent_run.id)
    end

    # @spec CHAT-PR-PROPOSAL-006
    it "uses custom prompt metadata when no issue is present" do
      prompt = <<~PROMPT
        Create a new RDR document file and update the README index.

        Open a PR titled `docs(rdr): RDR-053 - New Feature Creation` with a docs-only diff.
      PROMPT
      agent_run_no_issue = create(:agent_run, :with_custom_prompt, :with_git_context, project: project,
        custom_prompt: prompt)

      expect(github_client).to receive(:create_pull_request).with(
        anything,
        hash_including(
          title: "docs(rdr): RDR-053 - New Feature Creation",
          body: a_string_including("Create a new RDR document file and update the README index.")
        )
      ).and_return(pr_response)

      result = activity.execute(agent_run_id: agent_run_no_issue.id)
      expect(result[:pull_request_url]).to eq("https://github.com/owner/repo/pull/42")
    end

    # @spec CHAT-PR-PROPOSAL-006
    it "uses custom prompt fallback descriptions in PR templates" do
      PrTemplate.create!(
        account: project.account, project: project, name: "default",
        body: "## Summary\n\n{{description}}\n\n## Test Plan\n\n{{quality_warnings}}",
        pr_type: "default", position: 0, enabled: true
      )
      agent_run_no_issue = create(:agent_run, :with_custom_prompt, :with_git_context, project: project,
        custom_prompt: "Write the RDR draft and update the index.")

      expect(github_client).to receive(:create_pull_request).with(
        anything,
        hash_including(body: a_string_including("Write the RDR draft and update the index."))
      ).and_return(pr_response)

      activity.execute(agent_run_id: agent_run_no_issue.id)
    end

    # @spec CHAT-PR-PROPOSAL-006
    it "does not include trailing instructions in unquoted custom prompt PR titles" do
      agent_run_no_issue = create(:agent_run, :with_custom_prompt, :with_git_context, project: project,
        custom_prompt: "Open a PR titled docs(rdr): RDR-053 - New Feature Creation with a docs-only diff.")

      expect(github_client).to receive(:create_pull_request).with(
        anything,
        hash_including(title: "docs(rdr): RDR-053 - New Feature Creation")
      ).and_return(pr_response)

      activity.execute(agent_run_id: agent_run_no_issue.id)
    end

    # @spec CHAT-PR-PROPOSAL-006
    it "redacts secrets from custom prompt fallback metadata" do
      token = "ghp_" + "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmn"
      agent_run_no_issue = create(:agent_run, :with_custom_prompt, :with_git_context, project: project,
        custom_prompt: "Rotate #{token} and update docs.")

      expect(github_client).to receive(:create_pull_request).with(
        anything,
        hash_including(
          title: a_string_including("[REDACTED:github_token]"),
          body: a_string_including("[REDACTED:github_token]")
        )
      ).and_return(pr_response)

      activity.execute(agent_run_id: agent_run_no_issue.id)
    end

    # @spec CHAT-PR-PROPOSAL-008
    it "neutralizes markdown links and images in the custom prompt fallback body" do
      agent_run_no_issue = create(:agent_run, :with_custom_prompt, :with_git_context, project: project,
        custom_prompt: "![track](https://evil.example/pixel) Click [here](https://phish.example).")

      expect(github_client).to receive(:create_pull_request).with(
        anything,
        hash_including(
          body: a_string_including("! [track] (https://evil.example/pixel)")
            .and(including("Click [here] (https://phish.example)"))
        )
      ).and_return(pr_response)

      activity.execute(agent_run_id: agent_run_no_issue.id)
    end

    it "handles missing issue gracefully" do
      agent_run_no_issue = create(:agent_run, :with_custom_prompt, :with_git_context, project: project)

      expect(github_client).to receive(:create_pull_request).with(
        anything,
        hash_including(title: "Make the requested changes")
      ).and_return(pr_response)

      result = activity.execute(agent_run_id: agent_run_no_issue.id)
      expect(result[:pull_request_url]).to eq("https://github.com/owner/repo/pull/42")
    end

    context "when the goal is lid_planning" do
      let(:lid_agent_run) do
        create(:agent_run, :with_git_context, project: project, goal: "lid_planning", issue: nil)
      end

      before do
        # All lid_planning runs require changed-file validation.
        # Set result_commit_sha and stub the compare API so the
        # allowlist check and output contract pass by default (a full
        # adoption artifact set). Tests that need different files
        # override the stub.
        lid_agent_run.update!(result_commit_sha: "abc123def456789012345678901234567890abcd")
        allow(github_client).to receive(:compare_changed_files)
          .and_return(full_adoption_files("AGENTS.md"))
      end

      it "uses the lid_planning PR title" do
        expect(github_client).to receive(:create_pull_request).with(
          anything,
          hash_including(title: "docs: bootstrap LID design tree")
        ).and_return(pr_response)

        result = activity.execute(agent_run_id: lid_agent_run.id)
        expect(result[:pull_request_url]).to eq("https://github.com/owner/repo/pull/42")
      end

      it "fetches changed files once for both allowlist and contract checks" do
        expect(github_client).to receive(:compare_changed_files)
          .with(project.full_name, lid_agent_run.base_commit_sha, lid_agent_run.result_commit_sha)
          .once
          .and_return(full_adoption_files("AGENTS.md"))

        activity.execute(agent_run_id: lid_agent_run.id)
      end

      it "uses goal-specific PR body when agent summary is present" do
        lid_agent_run.log!("stdout", "## LID Brownfield Analysis\n\nInferred decisions...")

        allow(AgentHarness).to receive(:send_message)
          .and_return(instance_double(AgentHarness::Response, success?: true,
                                     output: "Bootstrapped LID design tree with 5 LLDs and EARS specs."))

        captured_body = nil
        allow(github_client).to receive(:create_pull_request) do |*_args, **kwargs|
          captured_body = kwargs[:body]
          pr_response
        end

        activity.execute(agent_run_id: lid_agent_run.id)

        expect(captured_body).to include("Bootstrapped LID design tree")
      end

      it "falls back to goal-specific body when agent summary is blank" do
        captured_body = nil
        allow(github_client).to receive(:create_pull_request) do |*_args, **kwargs|
          captured_body = kwargs[:body]
          pr_response
        end

        activity.execute(agent_run_id: lid_agent_run.id)

        expect(captured_body).to include("This Planning PR bootstraps the LID design tree")
      end

      it "appends the Confirm these inferred decisions checklist from the agent summary" do
        summary = <<~SUMMARY
          ## LID Brownfield Analysis

          Bootstrapped LID design tree with 5 LLDs and EARS specs.

          ## Confirm these inferred decisions

          - [ ] auth: session tokens use JWT with RS256 (inferred from implementation)
          - [ ] api: rate limiting is per-account with sliding window (inferred from rack-attack config)
          - [ ] db: tenant isolation via RLS policies (inferred from schema)
        SUMMARY
        lid_agent_run.log!("stdout", summary)

        allow(AgentHarness).to receive(:send_message)
          .and_return(instance_double(AgentHarness::Response, success?: true,
                                     output: "Bootstrapped LID design tree with 5 LLDs and EARS specs."))

        captured_body = nil
        allow(github_client).to receive(:create_pull_request) do |*_args, **kwargs|
          captured_body = kwargs[:body]
          pr_response
        end

        activity.execute(agent_run_id: lid_agent_run.id)

        expect(captured_body).to include("Confirm these inferred decisions")
        expect(captured_body).to include("- [ ] auth: session tokens use JWT with RS256")
        expect(captured_body).to include("- [ ] db: tenant isolation via RLS policies")
      end

      it "does not duplicate checklist when description already contains it" do
        summary = <<~SUMMARY
          ## Confirm these inferred decisions

          - [ ] auth: session tokens use JWT with RS256
        SUMMARY
        lid_agent_run.log!("stdout", summary)

        # The generated description already includes the checklist
        allow(AgentHarness).to receive(:send_message)
          .and_return(instance_double(AgentHarness::Response, success?: true,
                                     output: "Bootstrapped LID design tree.\n\n## Confirm these inferred decisions\n\n- [ ] auth: session tokens use JWT with RS256"))

        captured_body = nil
        allow(github_client).to receive(:create_pull_request) do |*_args, **kwargs|
          captured_body = kwargs[:body]
          pr_response
        end

        activity.execute(agent_run_id: lid_agent_run.id)

        # Should appear exactly once
        occurrences = captured_body.scan("Confirm these inferred decisions").size
        expect(occurrences).to eq(1)
      end

      it "extracts checkbox block as checklist when no explicit heading exists" do
        summary = <<~SUMMARY
          ## LID Analysis

          Decisions inferred from codebase:

          - [ ] core: async job processing via GoodJob
          - [ ] api: GraphQL schema uses relay connections
        SUMMARY
        lid_agent_run.log!("stdout", summary)

        allow(AgentHarness).to receive(:send_message)
          .and_return(instance_double(AgentHarness::Response, success?: true,
                                     output: "Generated description without checklist."))

        captured_body = nil
        allow(github_client).to receive(:create_pull_request) do |*_args, **kwargs|
          captured_body = kwargs[:body]
          pr_response
        end
        activity.execute(agent_run_id: lid_agent_run.id)

        expect(captured_body).to include("Confirm these inferred decisions")
        expect(captured_body).to include("- [ ] core: async job processing via GoodJob")
      end

      it "extracts checkbox block as checklist with a single decision item" do
        summary = <<~SUMMARY
          ## LID Analysis

          Only one inferred decision this run:

          - [ ] core: async job processing via GoodJob
        SUMMARY
        lid_agent_run.log!("stdout", summary)

        allow(AgentHarness).to receive(:send_message)
          .and_return(instance_double(AgentHarness::Response, success?: true,
                                     output: "Generated description without checklist."))

        captured_body = nil
        allow(github_client).to receive(:create_pull_request) do |*_args, **kwargs|
          captured_body = kwargs[:body]
          pr_response
        end
        activity.execute(agent_run_id: lid_agent_run.id)

        expect(captured_body).to include("Confirm these inferred decisions")
        expect(captured_body).to include("- [ ] core: async job processing via GoodJob")
      end

      context "when the agent edits files outside the docs allowlist" do
        before do
          # The allowlist validation needs both commit SHAs to fetch changed
          # files from the GitHub compare API.
          lid_agent_run.update!(result_commit_sha: "abc123def456789012345678901234567890abcd")
        end

        it "raises an error when non-docs files are present" do
          allow(github_client).to receive(:compare_changed_files)
            .and_return([ "docs/high-level-design.md", "app/models/foo.rb" ])

          expect {
            activity.execute(agent_run_id: lid_agent_run.id)
          }.to raise_error(RuntimeError, /outside allowlist/)
        end

        it "raises an error when only non-docs files are present" do
          allow(github_client).to receive(:compare_changed_files)
            .and_return([ "app/models/foo.rb", "spec/models/foo_spec.rb" ])

          expect {
            activity.execute(agent_run_id: lid_agent_run.id)
          }.to raise_error(RuntimeError, /outside allowlist/)
        end

        it "allows docs/ files without raising" do
          allow(github_client).to receive(:compare_changed_files)
            .and_return(full_adoption_files("AGENTS.md") + [ "docs/README.md" ])

          expect { activity.execute(agent_run_id: lid_agent_run.id) }.not_to raise_error
        end

        it "allows instruction files without raising" do
          allow(github_client).to receive(:compare_changed_files)
            .and_return(full_adoption_files("AGENTS.md"))

          expect { activity.execute(agent_run_id: lid_agent_run.id) }.not_to raise_error
        end

        it "allows CLAUDE.md without raising" do
          allow(github_client).to receive(:compare_changed_files)
            .and_return(full_adoption_files("CLAUDE.md"))

          expect { activity.execute(agent_run_id: lid_agent_run.id) }.not_to raise_error
        end

        it "allows .github/copilot-instructions.md without raising" do
          allow(github_client).to receive(:compare_changed_files)
            .and_return(full_adoption_files(".github/copilot-instructions.md"))

          expect { activity.execute(agent_run_id: lid_agent_run.id) }.not_to raise_error
        end
      end

      # @spec LID-RUNS-007
      context "when adopting LID (project has no lid_mode)" do
        before do
          lid_agent_run.update!(result_commit_sha: "abc123def456789012345678901234567890abcd")
        end

        it "succeeds when the full artifact set is present" do
          allow(github_client).to receive(:compare_changed_files)
            .and_return(full_adoption_files("AGENTS.md"))

          expect { activity.execute(agent_run_id: lid_agent_run.id) }.not_to raise_error
        end

        it "raises when required artifacts are missing" do
          allow(github_client).to receive(:compare_changed_files)
            .and_return([ "docs/high-level-design.md", "docs/intent/auth/auth-specs.md" ])

          expect {
            activity.execute(agent_run_id: lid_agent_run.id)
          }.to raise_error(RuntimeError, /output contract violated/)
        end

        it "raises when no docs/intent artifacts were produced" do
          allow(github_client).to receive(:compare_changed_files)
            .and_return([ "docs/high-level-design.md", "AGENTS.md", "docs/arrows/index.yaml" ])

          expect {
            activity.execute(agent_run_id: lid_agent_run.id)
          }.to raise_error(RuntimeError, /output contract violated/)
        end
      end

      # @spec LID-RUNS-007
      context "when refining an existing LID project (lid_mode present)" do
        before do
          lid_agent_run.update!(result_commit_sha: "abc123def456789012345678901234567890abcd")
          project.update!(lid_mode: "full")
        end

        it "succeeds with only an LLD and EARS specs" do
          allow(github_client).to receive(:compare_changed_files)
            .and_return([ "docs/intent/billing/billing-design.md", "docs/intent/billing/billing-specs.md" ])

          expect { activity.execute(agent_run_id: lid_agent_run.id) }.not_to raise_error
        end

        it "raises when no EARS spec is present" do
          allow(github_client).to receive(:compare_changed_files)
            .and_return([ "docs/intent/billing/billing-design.md" ])

          expect {
            activity.execute(agent_run_id: lid_agent_run.id)
          }.to raise_error(RuntimeError, /output contract violated/)
        end
      end
    end

    # @spec CREATE-FEATURE-003
    context "when the goal is create_feature" do
      let(:feature_agent_run) do
        create(:agent_run, :with_git_context, :create_feature_goal, project: project, issue: nil,
          external_metadata: { "feature_brief" => { "title" => "Add dark mode", "problem" => "Eye strain" } })
      end
      let(:rdr_path) { "docs/rdrs/RDR-099-add-dark-mode.md" }

      before do
        feature_agent_run.update!(result_commit_sha: "abc123def456789012345678901234567890abcd")
        valid_rdr_body = <<~MARKDOWN
          # RDR-099: Add Dark Mode

          ## Metadata

          - Date: 2026-08-11

          ## Problem Statement

          Users want dark mode.

          ## Context

          The app uses ERB.

          ## Research Findings

          We read the codebase.

          ## Proposed Solution

          Add CSS variables.

          ## Alternatives Considered

          CSS-only.

          ## Trade-offs and Consequences

          Maintenance overhead.

          ## Rollout Guard

          Feature flag: dark_mode, default off.
          Enablement surface: `/tenant_configuration`.
          Implementation issue: add `dark_mode` to `FeatureFlags::DEFINITIONS`
          and guard runtime behavior with `FeatureFlags.enabled?(:dark_mode, project:)`.

          ## Implementation Plan

          Three phases.

          ## Validation

          Visual regression tests.
        MARKDOWN
        valid_index_body = "| [RDR-099](RDR-099-add-dark-mode.md) | Add Dark Mode | Draft | P1 |"

        allow(github_client).to receive(:compare_changed_files)
          .and_return([ rdr_path, "docs/rdrs/README.md" ])
        allow(github_client).to receive(:file_content).with(
          project.full_name, path: rdr_path, ref: feature_agent_run.result_commit_sha
        ).and_return(valid_rdr_body)
        allow(github_client).to receive(:file_content).with(
          project.full_name, path: "docs/rdrs/README.md", ref: feature_agent_run.result_commit_sha
        ).and_return(valid_index_body)
      end

      it "uses the create_feature PR title" do
        expect(github_client).to receive(:create_pull_request).with(
          anything,
          hash_including(title: "docs: RDR for Add dark mode")
        ).and_return(pr_response)

        result = activity.execute(agent_run_id: feature_agent_run.id)
        expect(result[:pull_request_url]).to eq("https://github.com/owner/repo/pull/42")
      end

      it "uses a create_feature-specific PR body" do
        captured_body = nil
        allow(github_client).to receive(:create_pull_request) do |*_args, **kwargs|
          captured_body = kwargs[:body]
          pr_response
        end

        activity.execute(agent_run_id: feature_agent_run.id)

        expect(captured_body).to include("Feature Creation RDR")
        expect(captured_body).to include("Add dark mode")
      end

      it "fetches changed files once for both allowlist and contract checks" do
        expect(github_client).to receive(:compare_changed_files)
          .with(project.full_name, feature_agent_run.base_commit_sha, feature_agent_run.result_commit_sha)
          .once
          .and_return([ rdr_path, "docs/rdrs/README.md" ])

        activity.execute(agent_run_id: feature_agent_run.id)
      end

      it "allows docs/rdrs/ files without raising" do
        expect { activity.execute(agent_run_id: feature_agent_run.id) }.not_to raise_error
      end

      context "when the agent edits files outside docs/rdrs/" do
        it "raises an error when code files are present" do
          allow(github_client).to receive(:compare_changed_files)
            .and_return([ rdr_path, "app/models/foo.rb" ])

          expect {
            activity.execute(agent_run_id: feature_agent_run.id)
          }.to raise_error(RuntimeError, /outside allowlist/)
        end

        it "raises an error when only code files are present" do
          allow(github_client).to receive(:compare_changed_files)
            .and_return([ "app/models/foo.rb", "spec/models/foo_spec.rb" ])

          expect {
            activity.execute(agent_run_id: feature_agent_run.id)
          }.to raise_error(RuntimeError, /outside allowlist/)
        end

        it "rejects docs outside docs/rdrs/" do
          allow(github_client).to receive(:compare_changed_files)
            .and_return([ rdr_path, "docs/intent/foo/foo-design.md" ])

          expect {
            activity.execute(agent_run_id: feature_agent_run.id)
          }.to raise_error(RuntimeError, /outside allowlist/)
        end
      end

      context "when the RDR output contract is violated" do
        it "raises when no RDR file was produced" do
          allow(github_client).to receive(:compare_changed_files)
            .and_return([ "docs/rdrs/README.md" ])

          expect {
            activity.execute(agent_run_id: feature_agent_run.id)
          }.to raise_error(RuntimeError, /output contract violated/)
        end

        it "raises when required RDR sections are missing" do
          incomplete_body = <<~MARKDOWN
            # RDR-099: Short

            ## Metadata

            - Date: 2026-08-11

            ## Problem Statement

            Just a problem.
          MARKDOWN
          allow(github_client).to receive(:file_content).with(
            project.full_name, path: rdr_path, ref: feature_agent_run.result_commit_sha
          ).and_return(incomplete_body)

          expect {
            activity.execute(agent_run_id: feature_agent_run.id)
          }.to raise_error(RuntimeError, /output contract violated/)
        end

        it "raises when the README index was not updated" do
          allow(github_client).to receive(:file_content).with(
            project.full_name, path: "docs/rdrs/README.md", ref: feature_agent_run.result_commit_sha
          ).and_return("# Index\n\nNo new entries.\n")

          expect {
            activity.execute(agent_run_id: feature_agent_run.id)
          }.to raise_error(RuntimeError, /output contract violated/)
        end
      end
    end

    # @spec TDD-GUARD-006
    context "when the run is TDD-governed" do
      let(:tdd_phase) { "refactor" }
      let(:tdd_agent_run) do
        create(:agent_run, :with_git_context, project: project, tdd_phase: tdd_phase, issue: nil, custom_prompt: "Fix the widget model")
      end

      before do
        tdd_agent_run.update!(result_commit_sha: "abc123def456789012345678901234567890abcd")
      end

      context "when in test_writing phase" do
        let(:tdd_phase) { "test_writing" }

        it "raises when implementation files are changed" do
          allow(github_client).to receive(:compare_changed_files)
            .and_return([ "spec/models/widget_spec.rb", "app/models/widget.rb" ])

          expect {
            activity.execute(agent_run_id: tdd_agent_run.id)
          }.to raise_error(RuntimeError, /TDD write guard violation/)
        end

        it "does not raise when only test files are changed" do
          allow(github_client).to receive(:compare_changed_files)
            .and_return([ "spec/models/widget_spec.rb" ])

          expect { activity.execute(agent_run_id: tdd_agent_run.id) }.not_to raise_error
        end

        it "refreshes an existing PR body with the test outline" do # @spec TDD-PR-001
          existing_pr = Struct.new(:html_url, :number, :body, :title).new(
            "https://github.com/owner/repo/pull/42",
            42,
            "## Summary\n\nExisting draft body",
            "Existing PR"
          )
          allow(github_client).to receive_messages(
            pull_requests: [ existing_pr ],
            compare_changed_files: [ "spec/models/widget_spec.rb" ]
          )
          allow(PullRequests::ReviewSurface).to receive(:call)
            .and_return("## Summary\n\nExisting draft body\n\n## Test Outline\n\n```text\nWidget\n```")

          activity.execute(agent_run_id: tdd_agent_run.id)

          expect(github_client).to have_received(:update_pull_request).with(
            project.full_name,
            42,
            body: include("## Test Outline")
          )
        end
      end

      context "when in test_fixing phase" do
        let(:tdd_phase) { "test_fixing" }

        it "raises when test files are changed without returning to test review" do
          allow(github_client).to receive(:compare_changed_files)
            .and_return([ "app/models/widget.rb", "spec/models/widget_spec.rb" ])

          expect {
            activity.execute(agent_run_id: tdd_agent_run.id)
          }.to raise_error(RuntimeError, /TDD write guard violation/)
        end

        it "does not raise when test files are changed after returning to test review" do
          tdd_agent_run.update!(tdd_returned_to_test_review: true)
          allow(github_client).to receive(:compare_changed_files)
            .and_return([ "app/models/widget.rb", "spec/models/widget_spec.rb" ])

          expect { activity.execute(agent_run_id: tdd_agent_run.id) }.not_to raise_error
        end
      end

      context "when in refactor phase" do
        let(:tdd_phase) { "refactor" }

        it "raises when test files are changed" do
          allow(github_client).to receive(:compare_changed_files)
            .and_return([ "app/models/widget.rb", "spec/models/widget_spec.rb" ])

          expect {
            activity.execute(agent_run_id: tdd_agent_run.id)
          }.to raise_error(RuntimeError, /TDD write guard violation/)
        end

        it "does not raise when only implementation files are changed" do
          allow(github_client).to receive(:compare_changed_files)
            .and_return([ "app/models/widget.rb" ])

          expect { activity.execute(agent_run_id: tdd_agent_run.id) }.not_to raise_error
        end
      end

      it "raises when changed file data is unavailable" do
        tdd_agent_run_no_sha = create(:agent_run, project: project, tdd_phase: "refactor", issue: nil, custom_prompt: "Fix the widget model")

        expect {
          activity.execute(agent_run_id: tdd_agent_run_no_sha.id)
        }.to raise_error(RuntimeError, /requires changed file data/)
      end
    end

    it "does not fail when label addition fails" do
      allow(github_client).to receive(:add_labels_to_issue)
        .and_raise(GithubClient::ApiError.new("Label not found"))

      expect {
        activity.execute(agent_run_id: agent_run.id)
      }.not_to raise_error
    end

    context "when auto_add_labels_enabled is false" do
      before { project.update!(auto_add_labels_enabled: false) }

      it "does not add labels to the PR" do
        activity.execute(agent_run_id: agent_run.id)

        expect(github_client).not_to have_received(:add_labels_to_issue)
      end
    end

    context "when auto_add_labels_enabled is true with custom labels" do
      before do
        project.update!(
          auto_add_labels_enabled: true,
          generated_label_name: "custom-generated",
          automation_label_name: "custom-automation"
        )
      end

      it "adds both custom labels to the PR" do
        activity.execute(agent_run_id: agent_run.id)

        expect(github_client).to have_received(:add_labels_to_issue).with(
          project.full_name, 42, [ "custom-generated", "custom-automation" ]
        )
        expect(project.issues.pull_requests_only.find_by!(github_number: 42).labels)
          .to include("custom-generated", "custom-automation")
      end
    end

    context "with priority label inheritance" do
      let(:project) do
        create(:project, priority_labels: { "P1" => "critical", "P2" => "high", "P3" => "low" })
      end
      let(:issue) { create(:issue, project: project, labels: [ "critical", "bug" ]) }
      let(:agent_run) { create(:agent_run, :with_git_context, :with_metrics, project: project, issue: issue) }

      it "copies matching priority labels from the issue to the PR" do
        activity.execute(agent_run_id: agent_run.id)

        expect(github_client).to have_received(:add_labels_to_issue).with(
          project.full_name, 42, [ "paid-generated", "paid-automation", "critical" ]
        )
      end

      context "when auto_add_labels is disabled but inheritance is on" do
        before { project.update!(auto_add_labels_enabled: false) }

        it "still adds inherited priority labels" do
          activity.execute(agent_run_id: agent_run.id)

          expect(github_client).to have_received(:add_labels_to_issue).with(
            project.full_name, 42, [ "critical" ]
          )
        end
      end

      context "when inherit_priority_labels is disabled" do
        before { project.update!(inherit_priority_labels: false) }

        it "does not copy priority labels" do
          activity.execute(agent_run_id: agent_run.id)

          expect(github_client).to have_received(:add_labels_to_issue).with(
            project.full_name, 42, [ "paid-generated", "paid-automation" ]
          )
        end
      end
    end

    context "when LLM generates a structured description" do
      let(:llm_description) { "## Summary\n\nAdds OAuth support for third-party integrations." }

      it "uses the LLM-generated description in the PR body" do
        agent_run.log!("stdout", "Added OAuth middleware")
        allow(AgentHarness).to receive(:send_message)
          .and_return(instance_double(AgentHarness::Response, success?: true, output: llm_description))

        expect(github_client).to receive(:create_pull_request).with(
          anything,
          hash_including(
            body: a_string_including("## Summary")
              .and(including("OAuth support"))
              .and(including("Closes ##{issue.github_number}"))
          )
        ).and_return(pr_response)

        activity.execute(agent_run_id: agent_run.id)
      end

      it "records a PR description metric when the LLM generates the description" do
        agent_run.log!("stdout", "Added OAuth middleware")
        allow(AgentHarness).to receive(:send_message)
          .and_return(instance_double(AgentHarness::Response, success?: true, output: llm_description))

        expect {
          activity.execute(agent_run_id: agent_run.id)
        }.to change(LlmOutputMetric, :count).by(1)

        metric = LlmOutputMetric.last
        expect(metric.project).to eq(project)
        expect(metric.output_type).to eq("pr_description")
        expect(metric.prompt_slug).to eq(Llm::GeneratePrDescription::PROMPT_SLUG)
        expect(metric.source_type).to eq("PullRequest")
        expect(metric.source_id).to eq(42)
        expect(metric.metadata["original_text"]).to eq("PR body")
      end

      it "passes issue context to the LLM service via AgentHarness" do
        agent_run.log!("stdout", "Added OAuth middleware")
        allow(AgentHarness).to receive(:send_message)
          .and_return(instance_double(AgentHarness::Response, success?: true, output: llm_description))

        activity.execute(agent_run_id: agent_run.id)

        expect(AgentHarness).to have_received(:send_message).with(
          a_string_including(issue.title).and(including(issue.body)),
          hash_including(
            provider: :claude,
            model: Llm::GeneratePrDescription::DEFAULT_MODEL,
            timeout: Llm::GeneratePrDescription::TIMEOUT
          )
        )
      end

      it "falls back to issue-title description when LLM retries are exhausted" do
        agent_run.log!("stdout", "Raw agent output here")
        allow(AgentHarness).to receive(:send_message)
          .and_raise(AgentHarness::ProviderError.new("Provider unavailable"))
        mock_logger = instance_double(ActiveSupport::Logger, info: nil)
        allow(activity).to receive(:logger).and_return(mock_logger)
        expect(mock_logger).to receive(:warn).with(hash_including(
          message: "agent_execution.pr_description_llm_unsuccessful",
          agent_run_id: agent_run.id,
          issue_number: issue.github_number
        ))
        expect(github_client).to receive(:create_pull_request).with(
          anything,
          hash_including(body: a_string_including(issue.title))
        ).and_return(pr_response)

        activity.execute(agent_run_id: agent_run.id)
      end

      it "falls back to issue-title description when LLM raises a non-retryable error" do
        agent_run.log!("stdout", "Raw agent output here")
        allow(AgentHarness).to receive(:send_message)
          .and_raise(RuntimeError.new("unexpected failure"))
        mock_logger = instance_double(ActiveSupport::Logger, info: nil)
        allow(activity).to receive(:logger).and_return(mock_logger)
        expect(mock_logger).to receive(:warn).with(hash_including(
          message: "agent_execution.pr_description_failed",
          agent_run_id: agent_run.id,
          issue_number: issue.github_number,
          error_class: "RuntimeError"
        ))
        expect(github_client).to receive(:create_pull_request).with(
          anything,
          hash_including(body: a_string_including(issue.title))
        ).and_return(pr_response)

        activity.execute(agent_run_id: agent_run.id)
      end

      it "falls back to issue-title description when LLM returns a failed response after retries" do
        agent_run.log!("stdout", "Raw agent output here")

        expect(github_client).to receive(:create_pull_request).with(
          anything,
          hash_including(
            body: a_string_including(issue.title)
          )
        ).and_return(pr_response)

        activity.execute(agent_run_id: agent_run.id)
      end

      it "does not record a PR description metric when LLM retries are exhausted" do
        agent_run.log!("stdout", "Raw agent output here")
        allow(AgentHarness).to receive(:send_message)
          .and_raise(AgentHarness::ProviderError.new("Provider unavailable"))

        expect {
          activity.execute(agent_run_id: agent_run.id)
        }.not_to change(LlmOutputMetric, :count)
      end

      it "logs an unsuccessful warning when LLM returns nil without raising" do
        agent_run.log!("stdout", "Raw agent output here")

        mock_logger = instance_double(ActiveSupport::Logger, info: nil, warn: nil)
        allow(activity).to receive(:logger).and_return(mock_logger)

        activity.execute(agent_run_id: agent_run.id)

        expect(mock_logger).to have_received(:warn).with(hash_including(
          message: "agent_execution.pr_description_llm_unsuccessful",
          agent_run_id: agent_run.id,
          issue_number: issue.github_number
        ))
      end
    end

    it "raises ActiveRecord::RecordNotFound for invalid agent_run_id" do
      expect {
        activity.execute(agent_run_id: -1)
      }.to raise_error(ActiveRecord::RecordNotFound)
    end

    context "when agent summary references a different issue (scope mismatch)" do
      let(:other_issue) { create(:issue, project: project, github_number: issue.github_number + 1000, github_state: "open") }

      before do
        other_issue # ensure created
        agent_run.log!("stdout", "Updated relationships_parsed_at for ##{other_issue.github_number}")
      end

      it "logs a scope mismatch warning" do
        mock_logger = instance_double(ActiveSupport::Logger, info: nil, warn: nil)
        allow(activity).to receive(:logger).and_return(mock_logger)

        activity.execute(agent_run_id: agent_run.id)

        expect(mock_logger).to have_received(:warn).with(hash_including(
          message: "agent_execution.summary_scope_mismatch",
          agent_run_id: agent_run.id,
          issue_number: issue.github_number,
          cross_referenced_issues: [ other_issue.github_number ]
        ))
      end

      it "adds a system log to the agent run about the mismatch" do
        activity.execute(agent_run_id: agent_run.id)

        warning_log = agent_run.agent_run_logs.reload.where(log_type: "system")
          .find { |l| l.content.include?("summary may describe a different issue") }
        expect(warning_log).to be_present
        expect(warning_log.content).to include("##{other_issue.github_number}")
      end

      it "still creates the PR successfully" do
        result = activity.execute(agent_run_id: agent_run.id)
        expect(result[:pull_request_url]).to eq("https://github.com/owner/repo/pull/42")
      end
    end

    context "when agent summary uses qualified owner/repo#NNN refs for a different issue" do
      let(:other_issue) { create(:issue, project: project, github_number: issue.github_number + 1000, github_state: "open") }

      before do
        other_issue
        agent_run.log!("stdout", "Fixed #{project.full_name}##{other_issue.github_number} by updating the scanner")
      end

      it "detects scope mismatch from qualified references" do
        mock_logger = instance_double(ActiveSupport::Logger, info: nil, warn: nil)
        allow(activity).to receive(:logger).and_return(mock_logger)

        activity.execute(agent_run_id: agent_run.id)

        expect(mock_logger).to have_received(:warn).with(hash_including(
          message: "agent_execution.summary_scope_mismatch",
          agent_run_id: agent_run.id,
          issue_number: issue.github_number,
          cross_referenced_issues: [ other_issue.github_number ]
        ))
      end
    end

    context "when agent summary uses qualified owner/repo#NNN ref for its own issue" do
      before do
        create(:issue, project: project, github_number: issue.github_number + 1000, github_state: "open")
        agent_run.log!("stdout", "Fixed #{project.full_name}##{issue.github_number} by updating the scanner")
      end

      it "does not log a scope mismatch warning" do
        activity.execute(agent_run_id: agent_run.id)

        mismatch_log = agent_run.agent_run_logs.reload.where(log_type: "system")
          .find { |l| l.content.include?("summary may describe a different issue") }
        expect(mismatch_log).to be_nil
      end
    end

    context "when agent summary references an external repo issue with a matching local number" do
      let(:other_issue) { create(:issue, project: project, github_number: issue.github_number + 1000, github_state: "open") }

      before do
        other_issue
        # The summary references an external repo whose issue number happens to
        # match a local sibling issue — this should NOT trigger a mismatch.
        agent_run.log!("stdout", "See also rails/rails##{other_issue.github_number} for upstream context on ##{issue.github_number}")
      end

      it "does not log a scope mismatch warning for external qualified references" do
        activity.execute(agent_run_id: agent_run.id)

        mismatch_log = agent_run.agent_run_logs.reload.where(log_type: "system")
          .find { |l| l.content.include?("summary may describe a different issue") }
        expect(mismatch_log).to be_nil
      end
    end

    context "when agent summary references own issue via external qualified ref with matching number" do
      let(:other_issue) { create(:issue, project: project, github_number: issue.github_number + 1000, github_state: "open") }

      before do
        other_issue
        # The summary references an external repo whose issue number matches the
        # current issue — this should NOT suppress mismatch detection for cross_refs.
        agent_run.log!("stdout", "See rails/rails##{issue.github_number} and also ##{other_issue.github_number}")
      end

      it "does not treat external qualified ref as own-issue mention and detects cross-ref mismatch" do
        mock_logger = instance_double(ActiveSupport::Logger, info: nil, warn: nil)
        allow(activity).to receive(:logger).and_return(mock_logger)

        activity.execute(agent_run_id: agent_run.id)

        expect(mock_logger).to have_received(:warn).with(hash_including(
          message: "agent_execution.summary_scope_mismatch",
          agent_run_id: agent_run.id,
          issue_number: issue.github_number,
          cross_referenced_issues: [ other_issue.github_number ]
        ))
      end
    end

    context "when agent summary uses differently-cased qualified ref for own repo" do
      before do
        create(:issue, project: project, github_number: issue.github_number + 1000, github_state: "open")
        agent_run.log!("stdout", "Fixed #{project.full_name.upcase}##{issue.github_number} by updating the scanner")
      end

      it "does not log a scope mismatch warning (case-insensitive match)" do
        activity.execute(agent_run_id: agent_run.id)

        mismatch_log = agent_run.agent_run_logs.reload.where(log_type: "system")
          .find { |l| l.content.include?("summary may describe a different issue") }
        expect(mismatch_log).to be_nil
      end
    end

    context "when agent summary contains in-token hash references like C#NNN" do
      let(:other_issue) { create(:issue, project: project, github_number: issue.github_number + 1000, github_state: "open") }

      before do
        other_issue
        # The summary contains a language/version token (C#) whose number happens
        # to match a sibling issue — this should NOT trigger a mismatch.
        agent_run.log!("stdout", "Updated the C##{other_issue.github_number} parser for ##{issue.github_number}")
      end

      it "does not treat in-token hash references as issue mentions" do
        activity.execute(agent_run_id: agent_run.id)

        mismatch_log = agent_run.agent_run_logs.reload.where(log_type: "system")
          .find { |l| l.content.include?("summary may describe a different issue") }
        expect(mismatch_log).to be_nil
      end
    end

    context "when agent summary contains no issue references at all" do
      before do
        create(:issue, project: project, github_number: issue.github_number + 1000, github_state: "open")
        agent_run.update!(result_commit_sha: "abc123def456789012345678901234567890abcd")
        agent_run.log!("stdout", "Refactored the parser module for better readability")
      end

      context "when summary overlaps with changed files" do
        before do
          allow(github_client).to receive(:compare_changed_files)
            .and_return([ "app/services/parser.rb" ])
        end

        it "does not log a scope mismatch warning" do
          activity.execute(agent_run_id: agent_run.id)

          mismatch_log = agent_run.agent_run_logs.reload.where(log_type: "system")
            .find { |l| l.content.include?("summary may describe a different issue") }
          expect(mismatch_log).to be_nil
        end
      end

      context "when summary has no overlap with changed files" do
        before do
          allow(github_client).to receive(:compare_changed_files)
            .and_return([ "app/models/user.rb", "db/migrate/001_create_users.rb" ])
        end

        it "logs a scope mismatch warning" do
          mock_logger = instance_double(ActiveSupport::Logger, info: nil, warn: nil)
          allow(activity).to receive(:logger).and_return(mock_logger)
          expect(mock_logger).to receive(:warn).with(hash_including(
            message: "agent_execution.summary_scope_mismatch",
            agent_run_id: agent_run.id,
            issue_number: issue.github_number,
            reason: "no_own_issue_ref_and_no_diff_overlap"
          ))

          activity.execute(agent_run_id: agent_run.id)
        end

        it "adds a system log about no overlap" do
          allow(github_client).to receive(:compare_changed_files)
            .and_return([ "app/models/user.rb" ])

          activity.execute(agent_run_id: agent_run.id)

          mismatch_log = agent_run.agent_run_logs.reload.where(log_type: "system")
            .find { |l| l.content.include?("summary may describe a different issue") }
          expect(mismatch_log).to be_present
          expect(mismatch_log.content).to include("no overlap with changed files")
        end
      end

      context "when compare API is unavailable" do
        before do
          allow(github_client).to receive(:compare_changed_files)
            .and_raise(GithubClient::ApiError.new("Not Found"))
        end

        it "does not log a scope mismatch warning (fails open)" do
          activity.execute(agent_run_id: agent_run.id)

          mismatch_log = agent_run.agent_run_logs.reload.where(log_type: "system")
            .find { |l| l.content.include?("summary may describe a different issue") }
          expect(mismatch_log).to be_nil
        end
      end
    end

    context "when agent summary references both its own issue and a sibling issue" do
      let(:other_issue) { create(:issue, project: project, github_number: issue.github_number + 1000, github_state: "open") }

      before do
        other_issue
        agent_run.log!("stdout", "Fixed ##{issue.github_number} and also updated ##{other_issue.github_number}")
      end

      it "does not log a scope mismatch warning" do
        activity.execute(agent_run_id: agent_run.id)

        mismatch_log = agent_run.agent_run_logs.reload.where(log_type: "system")
          .find { |l| l.content.include?("summary may describe a different issue") }
        expect(mismatch_log).to be_nil
      end

      it "logs cross-references at info level for observability" do
        mock_logger = instance_double(ActiveSupport::Logger, warn: nil)
        allow(activity).to receive(:logger).and_return(mock_logger)
        allow(mock_logger).to receive(:info)
        expect(mock_logger).to receive(:info).with(hash_including(
          message: "agent_execution.summary_cross_references",
          agent_run_id: agent_run.id,
          issue_number: issue.github_number,
          cross_referenced_issues: [ other_issue.github_number ]
        ))

        activity.execute(agent_run_id: agent_run.id)
      end
    end

    context "when validate_summary_scope raises an unexpected error" do
      before do
        agent_run.log!("stdout", "Fixed ##{issue.github_number} by updating the scanner")
        allow(activity).to receive(:sibling_open_issue_numbers).and_raise(ActiveRecord::StatementInvalid.new("DB gone"))
      end

      it "still creates the PR successfully" do
        result = activity.execute(agent_run_id: agent_run.id)
        expect(result[:pull_request_url]).to eq("https://github.com/owner/repo/pull/42")
      end

      it "logs the scope check failure" do
        mock_logger = instance_double(ActiveSupport::Logger, info: nil, warn: nil)
        allow(activity).to receive(:logger).and_return(mock_logger)

        activity.execute(agent_run_id: agent_run.id)

        expect(mock_logger).to have_received(:warn).with(hash_including(
          message: "agent_execution.summary_scope_check_failed",
          agent_run_id: agent_run.id,
          error_class: "ActiveRecord::StatementInvalid"
        ))
      end
    end

    context "when agent summary correctly references its own issue" do
      before do
        create(:issue, project: project, github_number: issue.github_number + 1000, github_state: "open")
        agent_run.log!("stdout", "Fixed ##{issue.github_number} by updating the scanner")
      end

      it "does not log a scope mismatch warning" do
        activity.execute(agent_run_id: agent_run.id)

        mismatch_log = agent_run.agent_run_logs.reload.where(log_type: "system")
          .find { |l| l.content.include?("summary may describe a different issue") }
        expect(mismatch_log).to be_nil
      end
    end

    context "with pre-run branch existence guard" do
      it "checks branch existence before creating a PR" do
        activity.execute(agent_run_id: agent_run.id)

        expect(github_client).to have_received(:ref).with(
          project.full_name,
          "heads/#{agent_run.branch_name}"
        )
      end

      it "creates a PR when branch exists but no PR is found" do
        allow(github_client).to receive_messages(ref: instance_double(Sawyer::Resource), pull_requests: [])

        result = activity.execute(agent_run_id: agent_run.id)

        expect(github_client).to have_received(:create_pull_request)
        expect(result[:pull_request_url]).to eq("https://github.com/owner/repo/pull/42")
      end

      it "raises when branch is confirmed missing (404)" do
        allow(github_client).to receive(:ref)
          .and_raise(GithubClient::NotFoundError.new("Not Found"))
        allow(github_client).to receive(:pull_requests).and_return([])

        expect {
          activity.execute(agent_run_id: agent_run.id)
        }.to raise_error(RuntimeError, /does not exist on GitHub/)

        expect(github_client).not_to have_received(:create_pull_request)
      end

      it "falls back to normal create flow when branch check raises a transient error" do
        allow(github_client).to receive(:ref)
          .and_raise(GithubClient::RateLimitError.new)
        allow(github_client).to receive(:pull_requests).and_return([])

        result = activity.execute(agent_run_id: agent_run.id)

        expect(github_client).to have_received(:create_pull_request)
        expect(result[:pull_request_url]).to eq("https://github.com/owner/repo/pull/42")
      end

      it "logs branch not found at info level" do
        allow(github_client).to receive(:ref)
          .and_raise(GithubClient::NotFoundError.new("Not Found"))
        allow(github_client).to receive(:pull_requests).and_return([])
        mock_logger = instance_double(ActiveSupport::Logger, warn: nil)
        allow(activity).to receive(:logger).and_return(mock_logger)
        allow(mock_logger).to receive(:info)

        expect(mock_logger).to receive(:info).with(hash_including(
          message: "agent_execution.branch_not_found",
          agent_run_id: agent_run.id,
          branch: agent_run.branch_name
        ))

        expect {
          activity.execute(agent_run_id: agent_run.id)
        }.to raise_error(RuntimeError, /does not exist on GitHub/)
      end

      it "logs branch check failure at warn level" do
        allow(github_client).to receive(:ref)
          .and_raise(Faraday::TimeoutError.new("timeout"))
        mock_logger = instance_double(ActiveSupport::Logger, info: nil)
        allow(activity).to receive(:logger).and_return(mock_logger)
        allow(mock_logger).to receive(:warn)

        expect(mock_logger).to receive(:warn).with(hash_including(
          message: "agent_execution.branch_check_failed",
          agent_run_id: agent_run.id,
          branch: agent_run.branch_name
        ))

        activity.execute(agent_run_id: agent_run.id)
      end
    end

    context "with idempotent retries" do
      let(:existing_pr) { Struct.new(:html_url, :number).new("https://github.com/owner/repo/pull/99", 99) }

      it "reuses an existing open PR instead of creating a new one" do
        allow(github_client).to receive(:pull_requests).and_return([ existing_pr ])

        result = activity.execute(agent_run_id: agent_run.id)

        expect(github_client).not_to have_received(:create_pull_request)
        expect(result[:pull_request_url]).to eq("https://github.com/owner/repo/pull/99")
        expect(result[:pull_request_number]).to eq(99)
        expect(agent_run.reload.status).to eq("completed")
        expect(agent_run.pull_request_url).to eq("https://github.com/owner/repo/pull/99")
      end

      it "still marks the run completed when post-processing raises" do
        allow(github_client).to receive(:add_labels_to_issue)
          .and_raise(StandardError.new("transient failure"))

        result = activity.execute(agent_run_id: agent_run.id)

        expect(agent_run.reload.status).to eq("completed")
        expect(result[:pull_request_url]).to eq("https://github.com/owner/repo/pull/42")
      end

      it "reuses existing PR on retry after partial failure with already-completed run" do
        # Simulate: first attempt created the PR and called complete!, but
        # the activity raised during post-processing. On retry, both the PR
        # and the completed status already exist.
        agent_run.complete!(
          result_commit: agent_run.result_commit_sha,
          pr_url: existing_pr.html_url,
          pr_number: existing_pr.number
        )
        allow(github_client).to receive(:pull_requests).and_return([ existing_pr ])

        result = activity.execute(agent_run_id: agent_run.id)

        expect(github_client).not_to have_received(:create_pull_request)
        expect(result[:pull_request_number]).to eq(99)
      end

      it "logs 'reused' when an existing PR is found" do
        allow(github_client).to receive(:pull_requests).and_return([ existing_pr ])

        activity.execute(agent_run_id: agent_run.id)

        log = agent_run.reload.agent_run_logs.last
        expect(log.content).to include("PR reused:")
      end

      it "falls through to create_pull_request when the lookup raises GithubClient::ApiError" do
        allow(github_client).to receive(:pull_requests).and_raise(GithubClient::ApiError.new("boom"))

        expect { activity.execute(agent_run_id: agent_run.id) }.not_to raise_error
        expect(github_client).to have_received(:create_pull_request)
        expect(agent_run.reload.status).to eq("completed")
      end

      it "falls through to create_pull_request when the lookup raises GithubClient::RateLimitError" do
        allow(github_client).to receive(:pull_requests).and_raise(GithubClient::RateLimitError.new)

        expect { activity.execute(agent_run_id: agent_run.id) }.not_to raise_error
        expect(github_client).to have_received(:create_pull_request)
        expect(agent_run.reload.status).to eq("completed")
      end

      it "reuses the existing PR when create raises a 422 already-exists error" do
        # First lookup finds nothing; the post-conflict lookup finds the PR.
        allow(github_client).to receive(:pull_requests).and_return([], [ existing_pr ])
        allow(github_client).to receive(:create_pull_request)
          .and_raise(GithubClient::ApiError.new("Validation Failed: A pull request already exists for owner:branch.", status: 422))

        result = activity.execute(agent_run_id: agent_run.id)

        expect(github_client).to have_received(:create_pull_request).once
        expect(result[:pull_request_number]).to eq(99)
        expect(result[:pull_request_url]).to eq("https://github.com/owner/repo/pull/99")
        expect(agent_run.reload.status).to eq("completed")
      end

      it "re-raises a non-already-exists 422 instead of treating it as a reuse signal" do
        allow(github_client).to receive(:pull_requests).and_return([])
        allow(github_client).to receive(:create_pull_request)
          .and_raise(GithubClient::ApiError.new("Validation Failed: base branch invalid", status: 422))

        expect {
          activity.execute(agent_run_id: agent_run.id)
        }.to raise_error(GithubClient::ApiError, /base branch invalid/)
        expect(github_client).to have_received(:create_pull_request).once
      end

      it "does not produce orphan branches when log! raises after completion" do
        allow(github_client).to receive(:pull_requests).and_return([])
        # agent_run.log! is called in best_effort, so even if it raises,
        # the run should be completed
        allow(agent_run).to receive(:log!).and_raise(StandardError.new("DB hiccup"))

        result = activity.execute(agent_run_id: agent_run.id)

        expect(agent_run.reload.status).to eq("completed")
        expect(agent_run.pull_request_url).to eq("https://github.com/owner/repo/pull/42")
        expect(result[:pull_request_url]).to eq("https://github.com/owner/repo/pull/42")
      end
    end
  end

  def capture_pr_body
    captured = nil
    allow(github_client).to receive(:create_pull_request) do |*_args, **kwargs|
      captured = kwargs[:body]
      pr_response
    end
    activity.execute(agent_run_id: agent_run.id)
    captured
  end

  def set_coherence_failure(summary_line:)
    agent_run.update!(
      external_metadata: {
        "lid_coherence" => { "status" => "failed", "summary_line" => summary_line }
      }
    )
  end
end
