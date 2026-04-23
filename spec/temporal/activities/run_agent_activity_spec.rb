# frozen_string_literal: true

require "rails_helper"

RSpec.describe Activities::RunAgentActivity do
  let(:activity) { described_class.new }
  let(:user) { create(:user) }
  let(:project) { create(:project, account: user.account, created_by: user) }
  let(:issue) { create(:issue, project: project) }
  let(:agent_run) { create(:agent_run, :with_git_context, project: project, issue: issue, container_id: "abc123") }
  let(:container_service) { instance_double(Containers::Provision) }
  let(:git_ops) { instance_double(Containers::GitOperations) }
  let(:exec_success) { Containers::Provision::Result.success(stdout: "Done", stderr: "", exit_code: 0) }
  let(:exec_failure) { Containers::Provision::Result.failure(error: "exit 1", stdout: "", stderr: "error", exit_code: 1) }

  before do
    # Ensure fallback is disabled by default so tests behave like single-provider runs
    user.settings.update!(fallback_enabled: false)

    # Stub github_client so effective_prompt → prompt_for_issue → BuildForIssue
    # does not make real HTTP calls (blocked by WebMock).
    github_client = instance_double(GithubClient, issue_comments: [])
    allow(project.github_token).to receive(:client).and_return(github_client)

    allow(AgentRun).to receive(:find).with(agent_run.id).and_return(agent_run)
    allow(Containers::Provision).to receive(:reconnect)
      .with(agent_run: agent_run, container_id: "abc123")
      .and_return(container_service)
    allow(Containers::GitOperations).to receive(:new)
      .with(container_service: container_service, agent_run: agent_run)
      .and_return(git_ops)
    allow(git_ops).to receive(:write_co_author_trailer)
  end

  def create_ab_test_assignment(slug:, agent_run:, variant_template:, status: "running")
    prompt = create(:prompt, :for_project, project: project, slug: slug)
    control_version = prompt.create_version!(template: "control {{base_prompt}}")
    variant_version = prompt.create_version!(template: variant_template)
    ab_test = create(:ab_test, prompt: prompt, control_version: control_version,
      status: status, started_at: Time.current)
    create(:ab_test_variant, ab_test: ab_test, prompt_version: control_version, is_control: true)
    variant = create(:ab_test_variant, ab_test: ab_test, prompt_version: variant_version)
    create(:ab_test_assignment, ab_test: ab_test, ab_test_variant: variant, agent_run: agent_run)

    variant_version
  end

  def create_running_ab_test(slug:)
    prompt = create(:prompt, :for_project, project: project, slug: slug)
    control_version = prompt.create_version!(template: "control {{base_prompt}} {{repo}}")
    variant_version = prompt.create_version!(template: "variant {{base_prompt}} {{repo}}")
    ab_test = create(:ab_test, prompt: prompt, control_version: control_version,
      status: "running", started_at: Time.current)
    create(:ab_test_variant, ab_test: ab_test, prompt_version: control_version, is_control: true)
    create(:ab_test_variant, ab_test: ab_test, prompt_version: variant_version)

    ab_test
  end

  describe "#with_periodic_heartbeat" do
    let(:mock_context) { instance_double(Temporalio::Activity::Context) }

    before do
      allow(mock_context).to receive(:heartbeat)
    end

    it "yields the block and returns its result" do
      allow(Temporalio::Activity::Context).to receive(:current_or_nil).and_return(mock_context)

      result = activity.send(:with_periodic_heartbeat, "test", interval: 0.01) { 42 }

      expect(result).to eq(42)
    end

    it "emits heartbeats while the block is running" do
      allow(Temporalio::Activity::Context).to receive(:current_or_nil).and_return(mock_context)

      activity.send(:with_periodic_heartbeat, "test", interval: 0.05) do
        sleep 0.15
        :done
      end

      expect(mock_context).to have_received(:heartbeat).with("test").at_least(:once)
    end

    it "propagates exceptions from the block with original backtrace" do
      allow(Temporalio::Activity::Context).to receive(:current_or_nil).and_return(mock_context)

      expect {
        activity.send(:with_periodic_heartbeat, "test", interval: 0.01) do
          raise ArgumentError, "boom"
        end
      }.to raise_error(ArgumentError, "boom") { |e|
        # Thread#value preserves the original backtrace from inside the
        # worker thread rather than replacing it with this call site.
        expect(e.backtrace.first).to include("run_agent_activity_spec.rb")
      }
    end

    it "does not report expected worker exceptions to stderr" do
      allow(Temporalio::Activity::Context).to receive(:current_or_nil).and_return(mock_context)

      expect {
        expect {
          activity.send(:with_periodic_heartbeat, "test", interval: 0.01) do
            raise ArgumentError, "boom"
          end
        }.to raise_error(ArgumentError, "boom")
      }.not_to output(/terminated with exception/).to_stderr
    end

    it "yields without heartbeating when outside activity context" do
      allow(Temporalio::Activity::Context).to receive(:current_or_nil).and_return(nil)

      result = activity.send(:with_periodic_heartbeat, "test") { 99 }

      expect(result).to eq(99)
    end

    it "re-raises CanceledError from heartbeat" do
      allow(Temporalio::Activity::Context).to receive(:current_or_nil).and_return(mock_context)
      allow(mock_context).to receive(:heartbeat).and_raise(Temporalio::Error::CanceledError, "canceled")

      expect {
        activity.send(:with_periodic_heartbeat, "test", interval: 0.01) do
          sleep 0.05
          :done
        end
      }.to raise_error(Temporalio::Error::CanceledError)
    end

    it "raises InfiniteLoopError when a loop is detected" do
      allow(Temporalio::Activity::Context).to receive(:current_or_nil).and_return(mock_context)

      loop_result = AgentRuns::DetectInfiniteLoop::Result.new(detected: true, reason: "test loop")
      allow(AgentRuns::DetectInfiniteLoop).to receive(:call).and_return(loop_result)

      expect {
        activity.send(:with_periodic_heartbeat, "test", interval: 0.01, agent_run: agent_run) do
          sleep 0.2
          :done
        end
      }.to raise_error(described_class::InfiniteLoopError, "test loop")
    end

    it "does not raise when no infinite loop is detected" do
      allow(Temporalio::Activity::Context).to receive(:current_or_nil).and_return(mock_context)

      no_loop_result = AgentRuns::DetectInfiniteLoop::Result.new(detected: false)
      allow(AgentRuns::DetectInfiniteLoop).to receive(:call).and_return(no_loop_result)

      result = activity.send(:with_periodic_heartbeat, "test", interval: 0.01, agent_run: agent_run) do
        sleep 0.05
        42
      end

      expect(result).to eq(42)
    end

    it "propagates tenant context into the worker thread" do
      allow(Temporalio::Activity::Context).to receive(:current_or_nil).and_return(mock_context)

      TenantContext.with(user.account) do
        result = nil

        expect {
          result = activity.send(:with_periodic_heartbeat, "test", interval: 0.01) do
            agent_run.log!("system", "tenant context propagated")
            [
              Current.account,
              ActiveRecord::Base.connection.select_value("SELECT paid_current_account_id()")
            ]
          end
        }.to change { agent_run.agent_run_logs.count }.by(1)

        expect(result).to eq([ user.account, user.account.id ])
        expect(agent_run.agent_run_logs.order(:id).last.content).to eq("tenant context propagated")
      end
    end
  end

  describe ".container_executable?" do
    it "recognizes codex as container executable" do
      expect(described_class.container_executable?("codex")).to be true
    end

    it "recognizes gemini as container executable" do
      expect(described_class.container_executable?("gemini")).to be true
    end

    it "recognizes kilocode as container executable" do
      expect(described_class.container_executable?("kilocode")).to be true
    end

    it "recognizes opencode as container executable" do
      expect(described_class.container_executable?("opencode")).to be true
    end

    it "does not treat copilot as container executable" do
      expect(described_class.container_executable?("copilot")).to be false
    end

    it "recognizes claude_code via agent type mapping" do
      expect(described_class.container_executable?("claude_code")).to be true
    end

    it "rejects unknown providers" do
      expect(described_class.container_executable?("unknown")).to be false
    end
  end

  describe "harness-generated commands" do
    it "generates codex command with sandbox bypass through agent-harness" do
      plan = Providers::HarnessExecutionPlan.for_provider_key(
        provider_key: "codex", prompt: "test", options: { dangerous_mode: true }
      )
      expect(plan.command).to include("codex", "exec")
      expect(plan.command).to include("--dangerously-bypass-approvals-and-sandbox")
    end

    it "generates claude command with dangerous-mode flags through agent-harness" do
      plan = Providers::HarnessExecutionPlan.for_provider_key(
        provider_key: "claude", prompt: "test", options: { dangerous_mode: true }
      )
      expect(plan.command).to include("claude", "--print", "--dangerously-skip-permissions")
    end
  end

  describe ".provider_order" do
    it "returns only the primary provider when fallback is disabled" do
      result = described_class.provider_order(
        agent_type: "claude_code",
        fallback_enabled: false,
        fallback_providers: %w[cursor aider]
      )

      expect(result).to eq([ "claude_code" ])
    end

    it "deduplicates canonical providers in fallback order" do
      result = described_class.provider_order(
        agent_type: "claude_code",
        fallback_enabled: true,
        fallback_providers: %w[claude cursor aider]
      )

      expect(result).to eq(%w[claude_code cursor aider])
    end

    it "includes codex in fallback order when listed" do
      result = described_class.provider_order(
        agent_type: "claude_code",
        fallback_enabled: true,
        fallback_providers: %w[codex cursor]
      )

      expect(result).to eq(%w[claude_code codex cursor])
    end

    it "includes gemini in fallback order when listed" do
      result = described_class.provider_order(
        agent_type: "claude_code",
        fallback_enabled: true,
        fallback_providers: %w[gemini codex]
      )

      expect(result).to eq(%w[claude_code gemini codex])
    end

    it "includes kilocode in fallback order when listed" do
      result = described_class.provider_order(
        agent_type: "claude_code",
        fallback_enabled: true,
        fallback_providers: %w[kilocode codex]
      )

      expect(result).to eq(%w[claude_code kilocode codex])
    end

    it "includes opencode in fallback order when listed" do
      result = described_class.provider_order(
        agent_type: "claude_code",
        fallback_enabled: true,
        fallback_providers: %w[opencode codex]
      )

      expect(result).to eq(%w[claude_code opencode codex])
    end

    it "skips copilot in fallback order because it is not an agent runner" do
      result = described_class.provider_order(
        agent_type: "claude_code",
        fallback_enabled: true,
        fallback_providers: %w[copilot codex]
      )

      expect(result).to eq(%w[claude_code codex])
    end
  end

  describe ".provider_attempt_count" do
    it "matches provider_order size for deduplicated fallback providers" do
      count = described_class.provider_attempt_count(
        agent_type: "claude_code",
        fallback_enabled: true,
        fallback_providers: %w[claude cursor aider]
      )

      expect(count).to eq(3)
    end
  end

  describe "#build_command" do
    it "builds a sh -c wrapper for Codex subscription auth" do
      context = described_class::CommandContext.new(
        provider_candidate: "codex",
        provider: "codex",
        user: nil
      )
      command = activity.send(:build_command, context, "say 'hi'")
      script = command[2]

      expect(command[0..1]).to eq(%w[sh -c])
      expect(script).to include('if [ "$PAID_CODEX_SUBSCRIPTION_AUTH" = "1" ]')
      expect(script).to include("-u OPENAI_API_KEY")
      expect(script).to include("codex")
      expect(command[3]).to eq("--")
      expect(command[4]).to eq("say 'hi'")
    end

    it "builds a sh -c wrapper for Gemini subscription auth" do
      context = described_class::CommandContext.new(
        provider_candidate: "gemini",
        provider: "gemini",
        user: nil
      )
      command = activity.send(:build_command, context, "say 'hi'")
      script = command[2]

      expect(command[0..1]).to eq(%w[sh -c])
      expect(script).to include('if [ "$PAID_GEMINI_SUBSCRIPTION_AUTH" = "1" ]')
      expect(script).to include("-u GEMINI_API_KEY")
      expect(script).to include("-u GOOGLE_GEMINI_BASE_URL")
      expect(script).to include("gemini")
      expect(command[3]).to eq("--")
      expect(command[4]).to eq("say 'hi'")
    end

    it "preserves multi-line prompts as a positional parameter" do
      multiline_prompt = "First line\nSecond line\n  indented third"
      context = described_class::CommandContext.new(
        provider_candidate: "codex",
        provider: "codex",
        user: nil
      )
      command = activity.send(:build_command, context, multiline_prompt)

      expect(command[4]).to eq(multiline_prompt)
      expect(command[2]).not_to include("\n")
    end

    it "returns the harness-generated command for non-subscription providers" do
      context = described_class::CommandContext.new(
        provider_candidate: "claude",
        provider: "claude",
        user: nil
      )
      command = activity.send(:build_command, context, "ping")

      expect(command).to include("claude", "--print", "--dangerously-skip-permissions")
      expect(command.last).to eq("ping")
    end

    it "builds an API-key wrapper for anthropic-backed fallback entries" do
      api_key = create(:provider_api_key, user: user, api_service_type: "anthropic", api_key: "sk-anthropic-secret")
      provider = create(:provider, :api_key, user: user, provider_key: "claude", provider_api_key: api_key)
      context = described_class::CommandContext.new(
        provider_candidate: provider.routing_key,
        provider: "claude",
        user: user
      )

      command = activity.send(:build_command, context, "ping")
      env = activity.send(:command_env_for, context, "ping")

      expect(command[0..1]).to eq(%w[sh -c])
      expect(command[2]).to include('ANTHROPIC_BASE_URL="$PAID_PROXY_URL/api/proxy/anthropic"')
      expect(command[2]).to include('ANTHROPIC_HEADER_X_AGENT_RUN_ID="$AGENT_RUN_ID"')
      expect(command[2]).to include('ANTHROPIC_HEADER_X_PROXY_TOKEN="$PROXY_TOKEN"')
      expect(command[2]).to include('ANTHROPIC_HEADER_X_PAID_PROVIDER_ID="$PAID_PROVIDER_ID"')
      expect(command[2]).to include('ANTHROPIC_API_KEY="paid-run:$AGENT_RUN_ID:$PROXY_TOKEN"')
      expect(command[2]).not_to include("sk-anthropic-secret")
      expect(command[3]).to eq("--")
      expect(command[4]).to eq("ping")
      expect(env).to eq("PAID_PROVIDER_ID" => provider.id.to_s)
    end

    it "builds an API-key wrapper for OpenAI-backed fallback entries without injecting the provider key" do
      api_key = create(:provider_api_key, user: user, api_service_type: "openai", api_key: "sk-openai-secret")
      provider = create(:provider, :api_key, user: user, provider_key: "codex", provider_api_key: api_key)
      context = described_class::CommandContext.new(
        provider_candidate: provider.routing_key,
        provider: "codex",
        user: user
      )

      command = activity.send(:build_command, context, "ping")
      env = activity.send(:command_env_for, context, "ping")

      expect(command[2]).to include('OPENAI_HEADER_X_PAID_PROVIDER_ID="$PAID_PROVIDER_ID"')
      expect(command[2]).to include('OPENAI_API_KEY="paid-run:$AGENT_RUN_ID:$PROXY_TOKEN"')
      expect(command[2]).not_to include("sk-openai-secret")
      expect(env).to eq("PAID_PROVIDER_ID" => provider.id.to_s)
    end

    it "builds an API-key wrapper for Google-backed fallback entries without injecting the provider key" do
      api_key = create(:provider_api_key, user: user, api_service_type: "google", api_key: "google-secret")
      provider = create(:provider, :api_key, user: user, provider_key: "gemini", provider_api_key: api_key)
      context = described_class::CommandContext.new(
        provider_candidate: provider.routing_key,
        provider: "gemini",
        user: user
      )

      command = activity.send(:build_command, context, "ping")
      env = activity.send(:command_env_for, context, "ping")

      expect(command[2]).to include('GOOGLE_HEADER_X_PAID_PROVIDER_ID="$PAID_PROVIDER_ID"')
      expect(command[2]).to include("X-Paid-Provider-Id: $PAID_PROVIDER_ID")
      expect(command[2]).to include('GEMINI_API_KEY="paid-run:$AGENT_RUN_ID:$PROXY_TOKEN"')
      expect(command[2]).to include('GOOGLE_API_KEY="paid-run:$AGENT_RUN_ID:$PROXY_TOKEN"')
      expect(command[2]).not_to include("google-secret")
      expect(env).to eq("PAID_PROVIDER_ID" => provider.id.to_s)
    end

    it "uses canonical provider state keys for subscription entries" do
      subscription_provider = user.providers.find_by!(provider_key: "claude")
      state_key = activity.send(:state_key_for, subscription_provider.routing_key, "claude", user)

      expect(state_key).to eq("claude")
    end

    context "with a direct-outbound OpenCode provider" do
      it "builds the command through agent-harness runtime preparation" do
        opencode_context = build_opencode_context(user)
        command = activity.send(:build_command, opencode_context, "ping")
        env = activity.send(:command_env_for, opencode_context, "ping")
        preparation = activity.send(:command_preparation_for, opencode_context, "ping")

        expect(command).to eq([ "env", "-u", "OPENAI_HEADER_X_AGENT_RUN_ID", "-u", "OPENAI_HEADER_X_PROXY_TOKEN", "opencode", "run", "ping" ])
        expect(env).to include("OPENAI_API_KEY" => "sk-openrouter-secret", "OPENAI_BASE_URL" => "https://openrouter.ai/api/v1")
        expect(preparation.file_writes.first.path).to eq("~/.config/opencode/opencode.json")
        expect(preparation.file_writes.first.content).to include("\"model\": \"moonshotai/kimi-k2-0905\"")
      end

      it "preserves multi-line prompts when wrapping the harness runtime command" do
        opencode_context = build_opencode_context(user)
        prompt = "line 1\nline 2"

        command = activity.send(:build_command, opencode_context, prompt)

        expect(command).to eq([ "env", "-u", "OPENAI_HEADER_X_AGENT_RUN_ID", "-u", "OPENAI_HEADER_X_PROXY_TOKEN", "opencode", "run", prompt ])
      end
    end
  end

  describe "#provider_entry_for" do
    it "memoizes routing-key lookups per user and identifier" do
      provider = create(:provider, user: user, provider_key: "opencode")

      expect(Provider).to receive(:for_identifier).once.with(user, provider.routing_key).and_call_original

      2.times do
        expect(activity.send(:provider_entry_for, provider.routing_key, user)).to eq(provider)
      end
    end
  end

  describe "#augment_prompt_for_enhance_issue_goal" do
    before do
      allow(Prompt).to receive(:resolve).and_return(nil)
    end

    it "includes knowledge context when artifacts are available" do
      base_prompt = "Enhance this issue with implementation context."
      allow(Knowledge::ContextBundle::Build).to receive(:call)
        .with(issue: issue, project: project)
        .and_return(content: "## Codebase Context\n\n- Hunt#last_active uses prey.updated_at")

      prompt = activity.send(:augment_prompt_for_enhance_issue_goal, agent_run, base_prompt)

      expect(prompt).to include(base_prompt)
      expect(prompt).to include("## Codebase Context")
      expect(prompt).to include("Hunt#last_active uses prey.updated_at")
      expect(prompt).to include("Read issue ##{issue.github_number} in #{project.full_name}")
    end

    it "renders without knowledge context when no artifacts are available" do
      base_prompt = "Enhance this issue with implementation context."
      allow(Knowledge::ContextBundle::Build).to receive(:call)
        .with(issue: issue, project: project)
        .and_return(content: "")

      prompt = activity.send(:augment_prompt_for_enhance_issue_goal, agent_run, base_prompt)

      expect(prompt).to include(base_prompt)
      expect(prompt).not_to include("## Codebase Context")
      expect(prompt).to include("Only add a comment to issue ##{issue.github_number}")
    end
  end

  describe "A/B test goal prompt assignment" do
    it "assigns a running test before rendering the issue-goal prompt" do
      run = create(:agent_run, :create_issue_goal, project: project)
      ab_test = create_running_ab_test(slug: described_class::ISSUE_GOAL_PROMPT_SLUG)

      prompt = activity.send(:augment_prompt_for_issue_goal, run, "Create a roadmap issue")

      assignment = AbTestAssignment.find_by!(ab_test: ab_test, agent_run: run)
      assigned_version = assignment.ab_test_variant.prompt_version

      expect(prompt).to eq(assigned_version.render(base_prompt: "Create a roadmap issue", repo: project.full_name))
      expect(run.reload.prompt_version).to eq(assigned_version)
    end

    it "uses an assigned issue-goal variant prompt version" do
      run = create(:agent_run, :create_issue_goal, project: project)
      variant_version = create_ab_test_assignment(
        slug: described_class::ISSUE_GOAL_PROMPT_SLUG,
        agent_run: run,
        variant_template: "variant {{base_prompt}} {{repo}}"
      )

      prompt = activity.send(:augment_prompt_for_issue_goal, run, "Create a roadmap issue")

      expect(prompt).to eq("variant Create a roadmap issue #{project.full_name}")
      expect(run.reload.prompt_version).to eq(variant_version)
    end

    it "uses an assigned review-goal variant prompt version" do
      run = create(:agent_run, :review_goal, project: project)
      variant_version = create_ab_test_assignment(
        slug: described_class::REVIEW_GOAL_PROMPT_SLUG,
        agent_run: run,
        variant_template: "review {{base_prompt}} {{repo}} {{pr_number}}"
      )

      prompt = activity.send(:augment_prompt_for_review_goal, run, "Review the branch")

      expect(prompt).to eq("review Review the branch #{project.full_name} #{run.source_pull_request_number}")
      expect(run.reload.prompt_version).to eq(variant_version)
    end

    it "uses an assigned enhance-issue variant prompt version" do
      run = create(:agent_run, :enhance_issue_goal, project: project, issue: issue)
      allow(Knowledge::ContextBundle::Build).to receive(:call)
        .with(issue: issue, project: project)
        .and_return(content: "")
      variant_version = create_ab_test_assignment(
        slug: described_class::ENHANCE_ISSUE_GOAL_PROMPT_SLUG,
        agent_run: run,
        variant_template: "enhance {{base_prompt}} {{repo}} {{issue_number}}"
      )

      prompt = activity.send(:augment_prompt_for_enhance_issue_goal, run, "Improve the issue")

      expect(prompt).to eq("enhance Improve the issue #{project.full_name} #{issue.github_number}")
      expect(run.reload.prompt_version).to eq(variant_version)
    end

    it "keeps using an existing assignment after the test stops running" do
      run = create(:agent_run, :create_issue_goal, project: project)
      variant_version = create_ab_test_assignment(
        slug: described_class::ISSUE_GOAL_PROMPT_SLUG,
        agent_run: run,
        variant_template: "assigned {{base_prompt}} {{repo}}",
        status: "completed"
      )
      variant_version.prompt.update!(active: false)

      prompt = activity.send(:augment_prompt_for_issue_goal, run, "Create a roadmap issue")

      expect(prompt).to eq("assigned Create a roadmap issue #{project.full_name}")
      expect(run.reload.prompt_version).to eq(variant_version)
    end
  end

  describe "#build_provider_order" do
    it "preserves routing-key fallback entries for agent-type runs" do
      api_key = create(:provider_api_key, user: user, api_service_type: "openrouter")
      opencode_provider = create_opencode_provider_entry(
        user: user,
        api_key: api_key,
        name: "Kimi K2.5",
        model: "moonshotai/kimi-k2-0905"
      )
      user.settings.update!(fallback_enabled: true, fallback_providers: [ opencode_provider.routing_key ])

      providers = activity.send(:build_provider_order, agent_run, user.settings)

      expect(providers).to eq([ "claude_code", opencode_provider.routing_key ])
    end

    it "wraps saved fallback order after the active primary provider entry" do
      claude = user.providers.find_by!(provider_key: "claude")
      cursor = create(:provider, user: user, provider_key: "cursor")
      aider = create(:provider, user: user, provider_key: "aider")
      provider_run = create(:agent_run, :with_git_context, project: project,
        issue: create(:issue, project: project), provider: cursor, agent_type: "cursor", container_id: "abc123")
      user.settings.update!(fallback_enabled: true,
        fallback_providers: [ claude.routing_key, cursor.routing_key, aider.routing_key ])

      providers = activity.send(:build_provider_order, provider_run, user.settings)

      expect(providers).to eq([ cursor.routing_key, aider.routing_key, claude.routing_key ])
    end

    it "filters an explicitly selected provider that is no longer container executable" do
      copilot_provider = create(:provider, user: user, provider_key: "copilot")
      codex_provider = create(:provider, user: user, provider_key: "codex")
      agent_run.update!(provider: copilot_provider, agent_type: "copilot")
      user.settings.update!(fallback_enabled: true, fallback_providers: [ codex_provider.routing_key ])

      providers = activity.send(:build_provider_order, agent_run, user.settings)

      expect(providers).to eq([ codex_provider.routing_key, user.providers.find_by!(provider_key: "claude").routing_key ])
      expect(providers).not_to include(copilot_provider.routing_key)
    end

    it "falls back to a runnable default when a saved provider is no longer container executable" do
      copilot_provider = create(:provider, user: user, provider_key: "copilot")
      agent_run.update!(provider: copilot_provider, agent_type: "copilot")
      user.settings.update!(fallback_enabled: false)

      providers = activity.send(:build_provider_order, agent_run, user.settings)

      expect(providers).to eq([ user.providers.find_by!(provider_key: "claude").routing_key ])
      expect(providers).not_to include(copilot_provider.routing_key)
    end
  end

  def build_opencode_context(user)
    api_key = create(:provider_api_key, user: user, api_service_type: "openrouter", api_key: "sk-openrouter-secret")
    provider = create_opencode_provider_entry(user: user, api_key: api_key, name: nil, model: "moonshotai/kimi-k2-0905")

    described_class::CommandContext.new(
      provider_candidate: provider.routing_key,
      provider: "opencode",
      user: user
    )
  end

  def expect_opencode_fallback_execution(opencode_provider)
    call_count = 0
    expect(container_service).to receive(:execute).twice do |command, **opts|
      call_count += 1
      if call_count == 1
        rate_limit_failure
      else
        expect(command[0..5]).to eq([ "env", "-u", "OPENAI_HEADER_X_AGENT_RUN_ID", "-u", "OPENAI_HEADER_X_PROXY_TOKEN", "opencode" ])
        expect(command[6]).to eq("run")
        expect(opts[:env]).to include("OPENAI_BASE_URL" => "https://openrouter.ai/api/v1")
        expect(opts[:preparation].file_writes.first.path).to eq("~/.config/opencode/opencode.json")
        exec_success
      end
    end

    result = activity.execute(agent_run_id: agent_run.id)

    expect(result[:success]).to be true
    expect(result[:final_provider]).to eq(opencode_provider.routing_key)
    expect(agent_run.reload.final_provider).to eq(opencode_provider.routing_key)
  end

  def expect_same_provider_rate_limit_fallback_execution(fallback_provider)
    logger = instance_double(ActiveSupport::Logger, info: nil, warn: nil, error: nil)
    allow(activity).to receive(:logger).and_return(logger)

    allow(container_service).to receive(:execute).twice do |command, **opts|
      if command.first == "claude"
        rate_limit_failure
      else
        expect(command[0..1]).to eq(%w[sh -c])
        expect(command[2]).to include('ANTHROPIC_BASE_URL="$PAID_PROXY_URL/api/proxy/anthropic"')
        expect(command[2]).to include('ANTHROPIC_HEADER_X_AGENT_RUN_ID="$AGENT_RUN_ID"')
        expect(command[2]).to include('ANTHROPIC_HEADER_X_PROXY_TOKEN="$PROXY_TOKEN"')
        expect(command[2]).to include('ANTHROPIC_API_KEY="paid-run:$AGENT_RUN_ID:$PROXY_TOKEN"')
        expect(command[2]).not_to include("sk-fallback-secret")
        expect(opts[:env]).to include("PAID_PROVIDER_ID" => fallback_provider.id.to_s)
        exec_success
      end
    end
    allow(git_ops).to receive(:has_changes_since?).and_return(false)

    result = activity.execute(agent_run_id: agent_run.id)

    expect(result[:success]).to be true
    expect(result[:final_provider]).to eq(fallback_provider.routing_key)
    expect(agent_run.reload.final_provider).to eq(fallback_provider.routing_key)
    expect(agent_run.providers_attempted.map { |attempt| attempt["provider"] }).to eq([ "claude_code", fallback_provider.routing_key ])
    expect(agent_run.provider_switches).to eq(1)
    expect(logger).to have_received(:info).with(
      hash_including(
        message: "agent_execution.rate_limit_fallback_available",
        provider: "claude",
        agent_run_id: agent_run.id,
        fallback_providers: [ fallback_provider.routing_key ]
      )
    )
  end

  def create_claude_rate_limit_fallback_provider(api_key: "sk-fallback-secret")
    create(
      :provider,
      :rate_limit_fallback,
      user: user,
      provider_key: "claude",
      provider_api_key: create(:provider_api_key, user: user, api_service_type: "anthropic", api_key: api_key),
      enabled_for_agent_runs: true,
      enabled_for_fallback: true,
      name: "Claude API Key"
    )
  end

  def create_opencode_provider_entry(user:, api_key:, name:, model:)
    create(
      :provider,
      user: user,
      provider_key: "opencode",
      auth_type: "api_key",
      provider_api_key: api_key,
      name: name || "",
      enabled_for_agent_runs: true,
      config: { "opencode" => { "api_provider" => "openrouter", "model" => model } }
    )
  end

  def expect_change_detection_retry_logs(logger, operation:)
    expect(logger).to have_received(:warn).with(hash_including(
      message: "agent_execution.change_detection_retry",
      operation: operation,
      attempt: 1
    ))
    expect(logger).to have_received(:warn).with(hash_including(
      message: "agent_execution.change_detection_retry",
      operation: operation,
      attempt: 2
    ))
    expect(logger).to have_received(:error).with(hash_including(
      message: "agent_execution.change_detection_failed",
      operation: operation,
      attempt: 3,
      transient: true
    ))
  end

  def expect_non_retryable_post_run_error(error, operation:)
    expect(error).to be_a(Temporalio::Error::ApplicationError)
    expect(error.type).to eq(Activities::RunAgentActivity::POST_RUN_BOOKKEEPING_ERROR_TYPE)
    expect(error.non_retryable).to be(true)
    expect(error.message).to include("Post-run #{operation} failed after 3 attempts")
  end

  def wrap_error(inner_error, message = "wrapped failure")
    begin
      raise inner_error
    rescue => e
      raise StandardError, "#{message}: #{e.class}: #{e.message}"
    end
  rescue => wrapped
    wrapped
  end

  def stub_reconnect_not_found_on_second_attempt
    attempts = 0
    allow(Containers::Provision).to receive(:reconnect) do
      attempts += 1
      if attempts == 2
        raise wrap_error(
          Containers::Provision::ProvisionError.new("Container #{agent_run.container_id} not found")
        )
      end
      container_service
    end
  end

  describe "#execute" do
    context "when agent succeeds in container" do
      before do
        allow(container_service).to receive(:execute).and_return(exec_success)
        allow(git_ops).to receive_messages(head_sha: "pre_agent_sha_abc123", commit_uncommitted_changes: false)
      end

      it "executes the agent CLI inside the container" do
        allow(git_ops).to receive(:has_changes_since?).and_return(false)

        expect(container_service).to receive(:execute).with(
          array_including("claude", "--print", "--dangerously-skip-permissions"),
          hash_including(timeout: anything)
        ).and_return(exec_success)

        activity.execute(agent_run_id: agent_run.id)
      end

      it "captures HEAD SHA before running the agent" do
        allow(git_ops).to receive(:has_changes_since?).and_return(false)

        expect(git_ops).to receive(:head_sha).and_return("pre_agent_sha_abc123")

        activity.execute(agent_run_id: agent_run.id)
      end

      it "starts the agent run before execution" do
        allow(git_ops).to receive(:has_changes_since?).and_return(false)

        activity.execute(agent_run_id: agent_run.id)

        expect(agent_run.reload.status).to eq("running")
      end

      it "returns has_changes: true when agent made new commits" do
        allow(git_ops).to receive(:has_changes_since?).with("pre_agent_sha_abc123").and_return(true)

        result = activity.execute(agent_run_id: agent_run.id)

        expect(result[:has_changes]).to be true
        expect(result[:success]).to be true
      end

      it "returns has_changes: false when agent made no changes" do
        allow(git_ops).to receive(:has_changes_since?).with("pre_agent_sha_abc123").and_return(false)

        result = activity.execute(agent_run_id: agent_run.id)

        expect(result[:has_changes]).to be false
        expect(result[:success]).to be true
      end

      it "returns review_threads_already_addressed when the agent emits the marker" do
        marker_success = Containers::Provision::Result.success(
          stdout: "Reviewed the branch.\n#{Prompts::BuildForPr::ALREADY_ADDRESSED_MARKER}\n",
          stderr: "",
          exit_code: 0
        )
        allow(container_service).to receive(:execute).and_return(marker_success)
        allow(git_ops).to receive(:has_changes_since?).with("pre_agent_sha_abc123").and_return(false)

        result = activity.execute(agent_run_id: agent_run.id)

        expect(result[:review_threads_already_addressed]).to be(true)
        expect(result[:has_changes]).to be(false)
      end

      it "succeeds and logs an informational message when provider has no output and no changes" do
        no_output_success = Containers::Provision::Result.success(stdout: "", stderr: "", exit_code: 0)
        allow(container_service).to receive(:execute).and_return(no_output_success)
        allow(git_ops).to receive(:has_changes_since?).with("pre_agent_sha_abc123").and_return(false)

        result = activity.execute(agent_run_id: agent_run.id)

        expect(result[:success]).to be true
        expect(result[:has_changes]).to be false
        expect(agent_run.reload.agent_run_logs.where(
          log_type: "system",
          content: "Provider completed with no output and no changes"
        )).to exist
      end

      it "succeeds when provider output is binary encoded" do
        binary_success = Containers::Provision::Result.success(
          stdout: "Done \xFF".b,
          stderr: "",
          exit_code: 0
        )
        allow(container_service).to receive(:execute).and_return(binary_success)
        allow(git_ops).to receive(:has_changes_since?).with("pre_agent_sha_abc123").and_return(false)

        result = activity.execute(agent_run_id: agent_run.id)

        expect(result[:success]).to be true
        expect(result[:final_provider]).to eq("claude_code")
        expect(agent_run.reload.final_provider).to eq("claude_code")
        expect(agent_run.providers_attempted.map { |attempt| attempt["provider"] }).to eq([ "claude_code" ])
      end

      context "when agent-harness can parse token usage from CLI output" do
        let(:agent_run) { create(:agent_run, :kilocode, :with_git_context, project: project, issue: issue, container_id: "abc123") }
        let(:exec_success) do
          Containers::Provision::Result.success(
            stdout: [
              { type: "text", text: "Done" }.to_json,
              { type: "usage", usage: { input_tokens: 1200, output_tokens: 300, total_tokens: 1500 } }.to_json
            ].join("\n"),
            stderr: "",
            exit_code: 0
          )
        end

        it "records run summary usage and updates billable run aggregates" do
          allow(git_ops).to receive(:has_changes_since?).with("pre_agent_sha_abc123").and_return(false)

          activity.execute(agent_run_id: agent_run.id)

          usages = agent_run.token_usages.order(:request_type)
          expect(usages.pluck(:request_type, :input_tokens, :output_tokens)).to eq([
            [ "run_delta", 1200, 300 ],
            [ "run_summary", 1200, 300 ]
          ])
          expect(agent_run.reload.tokens_input).to eq(1200)
          expect(agent_run.tokens_output).to eq(300)
        end

        it "does not subtract proxy usage from previous failed provider attempts" do
          TokenUsage.create!(
            agent_run: agent_run,
            request_type: "agent",
            input_tokens: 700,
            output_tokens: 100,
            cost_cents: 1,
            llm_model: "claude-sonnet-4",
            created_at: 2.hours.ago,
            updated_at: 2.hours.ago
          )
          allow(git_ops).to receive(:has_changes_since?).with("pre_agent_sha_abc123").and_return(false)

          activity.execute(agent_run_id: agent_run.id)

          expect(agent_run.token_usages.find_by!(request_type: "run_delta")).to have_attributes(
            input_tokens: 1200,
            output_tokens: 300
          )
          expect(agent_run.reload.tokens_input).to eq(1200)
          expect(agent_run.tokens_output).to eq(300)
        end
      end

      it "retries transient commit failures before checking for changes" do
        commit_attempts = 0

        allow(activity).to receive(:sleep)
        allow(git_ops).to receive(:commit_uncommitted_changes) do
          commit_attempts += 1
          raise Docker::Error::DockerError, "docker unavailable" if commit_attempts == 1

          true
        end
        allow(git_ops).to receive(:has_changes_since?).with("pre_agent_sha_abc123").and_return(true)

        result = activity.execute(agent_run_id: agent_run.id)

        expect(result[:has_changes]).to be true
        expect(git_ops).to have_received(:commit_uncommitted_changes).twice
        expect(activity).to have_received(:sleep).with(0.25)
      end

      it "retries wrapped container exec failures before checking for changes" do
        commit_attempts = 0

        allow(activity).to receive(:sleep)
        allow(git_ops).to receive(:commit_uncommitted_changes) do
          commit_attempts += 1
          if commit_attempts == 1
            raise wrap_error(
              Containers::Provision::ExecutionError.new("Docker exec error: Connection reset")
            )
          end

          true
        end
        allow(git_ops).to receive(:has_changes_since?).with("pre_agent_sha_abc123").and_return(true)

        result = activity.execute(agent_run_id: agent_run.id)

        expect(result[:has_changes]).to be true
        expect(git_ops).to have_received(:commit_uncommitted_changes).twice
        expect(activity).to have_received(:sleep).with(0.25)
      end

      it "auto-commits uncommitted changes after agent runs" do
        allow(git_ops).to receive(:has_changes_since?).and_return(true)

        expect(git_ops).to receive(:commit_uncommitted_changes).and_return(true)

        activity.execute(agent_run_id: agent_run.id)
      end

      it "falls back to has_changes? when pre_agent_sha capture fails" do
        allow(git_ops).to receive(:head_sha).and_raise(StandardError, "container not ready")
        allow(git_ops).to receive_messages(commit_uncommitted_changes: false, has_changes?: true)
        allow(git_ops).to receive(:has_changes_since?)

        result = activity.execute(agent_run_id: agent_run.id)

        expect(result[:has_changes]).to be true
        expect(git_ops).not_to have_received(:has_changes_since?)
      end

      it "retries transient change-detection failures before succeeding" do
        change_attempts = 0

        allow(activity).to receive(:sleep)
        allow(git_ops).to receive(:has_changes_since?).with("pre_agent_sha_abc123") do
          change_attempts += 1
          raise Docker::Error::DockerError, "docker unavailable" if change_attempts == 1

          true
        end

        result = activity.execute(agent_run_id: agent_run.id)

        expect(result[:has_changes]).to be true
        expect(git_ops).to have_received(:has_changes_since?).twice
        expect(activity).to have_received(:sleep).with(0.25)
      end

      it "retries socket-level container reconnect failures before succeeding" do
        change_attempts = 0

        allow(activity).to receive(:sleep)
        allow(git_ops).to receive(:has_changes_since?).with("pre_agent_sha_abc123") do
          change_attempts += 1
          raise Errno::ECONNREFUSED, "Connection refused" if change_attempts == 1

          true
        end

        result = activity.execute(agent_run_id: agent_run.id)

        expect(result[:has_changes]).to be true
        expect(git_ops).to have_received(:has_changes_since?).twice
        expect(activity).to have_received(:sleep).with(0.25)
      end

      it "retries wrapped socket-level container reconnect failures before succeeding" do
        change_attempts = 0

        allow(activity).to receive(:sleep)
        allow(git_ops).to receive(:has_changes_since?).with("pre_agent_sha_abc123") do
          change_attempts += 1
          raise wrap_error(Errno::ECONNREFUSED.new("Connection refused")) if change_attempts == 1

          true
        end

        result = activity.execute(agent_run_id: agent_run.id)

        expect(result[:has_changes]).to be true
        expect(git_ops).to have_received(:has_changes_since?).twice
        expect(activity).to have_received(:sleep).with(0.25)
      end

      it "retries transient fallback change-detection failures before succeeding" do
        change_attempts = 0

        allow(activity).to receive(:sleep)
        allow(git_ops).to receive(:head_sha).and_raise(StandardError, "container not ready")
        allow(git_ops).to receive(:commit_uncommitted_changes).and_return(false)
        allow(git_ops).to receive(:has_changes?) do
          change_attempts += 1
          raise Docker::Error::DockerError, "docker unavailable" if change_attempts == 1

          true
        end
        allow(git_ops).to receive(:has_changes_since?)

        result = activity.execute(agent_run_id: agent_run.id)

        expect(result[:has_changes]).to be true
        expect(git_ops).to have_received(:has_changes?).twice
        expect(git_ops).not_to have_received(:has_changes_since?)
        expect(activity).to have_received(:sleep).with(0.25)
      end

      it "retries wrapped container reconnect failures before succeeding" do
        attempts = 0

        allow(activity).to receive(:sleep)
        allow(Containers::Provision).to receive(:reconnect) do
          attempts += 1
          if attempts == 2
            raise wrap_error(
              Containers::Provision::ProvisionError.new("Failed to reconnect to container: connection reset")
            )
          end

          container_service
        end
        allow(git_ops).to receive(:has_changes_since?).with("pre_agent_sha_abc123").and_return(true)

        result = activity.execute(agent_run_id: agent_run.id)

        expect(result[:has_changes]).to be true
        expect(Containers::Provision).to have_received(:reconnect).at_least(:twice)
        expect(activity).to have_received(:sleep).with(0.25)
      end

      it "does not retry permanent container-not-found reconnect failures" do
        allow(activity).to receive(:sleep)
        stub_reconnect_not_found_on_second_attempt

        expect {
          activity.execute(agent_run_id: agent_run.id)
        }.to raise_error(Temporalio::Error::ApplicationError) { |error|
          aggregate_failures do
            expect(error.type).to eq("PostRunBookkeepingFailed")
            expect(error.non_retryable).to be(true)
            expect(error.message).to include("Post-run commit_uncommitted_changes failed after 1 attempts")
            expect(error.message).to include("Containers::Provision::ProvisionError")
            expect(error.message).to include("not found")
          end
        }
        expect(activity).not_to have_received(:sleep)
        expect(Containers::Provision).to have_received(:reconnect).twice
      end

      it "raises a non-retryable ApplicationError when change detection keeps failing after transient retries" do
        logger = instance_double(ActiveSupport::Logger, warn: nil, error: nil, info: nil)
        change_attempts = 0

        allow(activity).to receive(:logger).and_return(logger)
        allow(activity).to receive(:sleep)
        allow(git_ops).to receive(:has_changes_since?).with("pre_agent_sha_abc123") do
          change_attempts += 1
          raise Docker::Error::DockerError, "docker unavailable"
        end

        expect {
          activity.execute(agent_run_id: agent_run.id)
        }.to raise_error(Temporalio::Error::ApplicationError) { |error|
          expect_non_retryable_post_run_error(error, operation: "check_for_changes")
          expect(error.message).to include("Docker::Error::DockerError: docker unavailable")
        }

        expect(change_attempts).to eq(3)
        expect_change_detection_retry_logs(logger, operation: "check_for_changes")
      end

      it "raises a non-retryable ApplicationError when auto-commit keeps failing after transient retries" do
        logger = instance_double(ActiveSupport::Logger, warn: nil, error: nil, info: nil)
        commit_attempts = 0

        allow(activity).to receive(:logger).and_return(logger)
        allow(activity).to receive(:sleep)
        allow(git_ops).to receive(:commit_uncommitted_changes) do
          commit_attempts += 1
          raise Errno::ECONNREFUSED, "Connection refused"
        end

        expect {
          activity.execute(agent_run_id: agent_run.id)
        }.to raise_error(Temporalio::Error::ApplicationError) { |error|
          expect_non_retryable_post_run_error(error, operation: "commit_uncommitted_changes")
          expect(error.message).to include("Errno::ECONNREFUSED")
        }

        expect(commit_attempts).to eq(3)
        expect_change_detection_retry_logs(logger, operation: "commit_uncommitted_changes")
      end

      it "records the final_provider on success" do
        allow(git_ops).to receive(:has_changes_since?).and_return(false)

        result = activity.execute(agent_run_id: agent_run.id)

        expect(result[:final_provider]).to eq("claude_code")
        expect(agent_run.reload.final_provider).to eq("claude_code")
      end
    end

    context "when agent fails in container" do
      before do
        allow(git_ops).to receive(:head_sha).and_return("pre_agent_sha_abc123")
        allow(container_service).to receive(:execute).and_return(exec_failure)
      end

      it "raises AllProvidersExhausted when all providers fail" do
        expect {
          activity.execute(agent_run_id: agent_run.id)
        }.to raise_error(Temporalio::Error::ApplicationError, /All providers exhausted/)
      end

      it "marks the agent run as failed" do
        begin
          activity.execute(agent_run_id: agent_run.id)
        rescue Temporalio::Error::ApplicationError
          # expected
        end

        expect(agent_run.reload.status).to eq("failed")
      end
    end

    shared_examples "externally cancelled run" do |params|
      before do
        allow(git_ops).to receive(:head_sha).and_return("pre_agent_sha_abc123")
        allow(container_service).to receive(:execute) do
          AgentRun.where(id: agent_run.id).update_all(
            status: "timeout",
            error_message: params.fetch(:error_message),
            completed_at: Time.current
          )
          exec_failure
        end
      end

      it "does not increment the provider circuit-breaker failure_count" do
        state = user.provider_states.create!(provider_name: "claude", failure_count: 0, circuit_state: "closed")

        expect {
          activity.execute(agent_run_id: agent_run.id)
        }.to raise_error(Temporalio::Error::ApplicationError)

        expect(state.reload.failure_count).to eq(0)
        expect(state.circuit_state).to eq("closed")
      end

      it "records the provider attempt as cancelled_by_cleanup" do
        expect {
          activity.execute(agent_run_id: agent_run.id)
        }.to raise_error(Temporalio::Error::ApplicationError)

        attempts = agent_run.reload.providers_attempted
        expect(attempts.last["error_type"]).to eq("cancelled_by_cleanup")
        expect(attempts.last["success"]).to be false
      end

      it "preserves the cleanup error_message and timeout status on the run" do
        expect {
          activity.execute(agent_run_id: agent_run.id)
        }.to raise_error(Temporalio::Error::ApplicationError)

        agent_run.reload
        expect(agent_run.status).to eq("timeout")
        expect(agent_run.error_message).to start_with(params.fetch(:prefix))
      end

      it "stops iterating providers instead of attempting fallbacks" do
        user.settings.update!(fallback_enabled: true)

        expect {
          activity.execute(agent_run_id: agent_run.id)
        }.to raise_error(Temporalio::Error::ApplicationError)

        expect(agent_run.reload.providers_attempted.size).to eq(1)
      end

      it "does not enqueue ProcessRunQueueJob" do
        expect(ProcessRunQueueJob).not_to receive(:perform_later)

        expect {
          activity.execute(agent_run_id: agent_run.id)
        }.to raise_error(Temporalio::Error::ApplicationError)
      end
    end

    context "when the run is cancelled by dev:cleanup mid-execution" do
      it_behaves_like "externally cancelled run",
        prefix: AgentRun::STALE_CLEANUP_ERROR_PREFIX,
        error_message: "#{AgentRun::STALE_CLEANUP_ERROR_PREFIX}: process was restarted"
    end

    context "when the run is cancelled by StaleRunDetectorJob mid-execution" do
      it_behaves_like "externally cancelled run",
        prefix: AgentRun::STALE_DETECTOR_ERROR_PREFIX,
        error_message: "#{AgentRun::STALE_DETECTOR_ERROR_PREFIX}: stuck in 'running' beyond timeout threshold"
    end

    context "when agent hits rate limit (single provider)" do
      let(:rate_limit_output) do
        Containers::Provision::Result.failure(
          error: "rate limit", stdout: "",
          stderr: "You're out of extra usage \u00b7 resets 5am (UTC)", exit_code: 1
        )
      end

      def expect_prompt_echo_to_fail_without_rate_limit!(prompt:, output:)
        allow(agent_run).to receive(:effective_prompt).and_return(prompt)
        allow(container_service).to receive(:execute).and_return(output)

        expect {
          activity.execute(agent_run_id: agent_run.id)
        }.to raise_error(Temporalio::Error::ApplicationError, /All providers exhausted/)

        agent_run.reload

        expect(agent_run.status).to eq("failed")
        expect(agent_run.error_message).to include("All providers exhausted")
        expect(agent_run.error_message).not_to include("rate limited")

        provider_state = user.provider_states.find_by(provider_name: "claude")
        expect(provider_state&.rate_limited_until).to be_nil
      end

      before do
        allow(git_ops).to receive(:head_sha).and_return("pre_agent_sha_abc123")
        allow(container_service).to receive(:execute).and_return(rate_limit_output)
      end

      it "marks the agent run as rate_limited" do
        expect {
          activity.execute(agent_run_id: agent_run.id)
        }.to raise_error(Temporalio::Error::ApplicationError, /All providers exhausted/)

        agent_run.reload
        expect(agent_run.status).to eq("rate_limited")
        expect(agent_run.rate_limited_until).to be_present
        expect(agent_run.error_message).to include("rate limited")
      end

      it "detects Claude-specific usage limit error" do
        expect {
          activity.execute(agent_run_id: agent_run.id)
        }.to raise_error(Temporalio::Error::ApplicationError, /All providers exhausted/)

        expect(agent_run.reload.status).to eq("rate_limited")
      end

      it "marks the agent run as rate_limited when provider output is binary encoded" do
        binary_rate_limit_output = Containers::Provision::Result.failure(
          error: "rate limit",
          stdout: "",
          stderr: "You're out of extra usage \xB7 resets 5am (UTC)".b,
          exit_code: 1
        )
        allow(container_service).to receive(:execute).and_return(binary_rate_limit_output)

        expect {
          activity.execute(agent_run_id: agent_run.id)
        }.to raise_error(Temporalio::Error::ApplicationError, /All providers exhausted/)

        agent_run.reload
        expect(agent_run.status).to eq("rate_limited")
        expect(agent_run.rate_limited_until).to be_present
        expect(agent_run.error_message).to include("rate limited")
      end

      it "does not classify echoed prompt text as a rate limit" do
        echoed_prompt = <<~PROMPT
          Investigate why the secrets proxy returns 429 for token usage limits.
          Confirm whether the provider itself is actually rate limited.
        PROMPT
        prompt_echo_output = Containers::Provision::Result.failure(
          error: "killed", stdout: "", stderr: echoed_prompt, exit_code: 137
        )

        expect_prompt_echo_to_fail_without_rate_limit!(prompt: echoed_prompt, output: prompt_echo_output)
      end

      it "ignores prompt echoes wrapped in common prefixes" do
        echoed_prompt = <<~PROMPT
          Investigate why the secrets proxy returns 429 for token usage limits.
          Confirm whether the provider itself is actually rate limited.
        PROMPT
        prefixed_prompt_echo_output = Containers::Provision::Result.failure(
          error: "killed",
          stdout: "",
          stderr: <<~OUTPUT,
            user
            > Investigate why the secrets proxy returns 429 for token usage limits.
            > Confirm whether the provider itself is actually rate limited.
          OUTPUT
          exit_code: 137
        )

        expect_prompt_echo_to_fail_without_rate_limit!(prompt: echoed_prompt, output: prefixed_prompt_echo_output)
      end
    end

    context "when codex auth has expired" do
      let(:agent_run) do
        create(:agent_run, :with_git_context,
          project: project,
          issue: issue,
          agent_type: "codex",
          container_id: "abc123")
      end
      let(:auth_expired_output) do
        Containers::Provision::Result.failure(
          error: "exit 1",
          stdout: "",
          stderr: <<~STDERR,
            ERROR codex_core::auth: Failed to refresh token: 401 Unauthorized
            "message": "Your refresh token has already been used to generate a new access token. Please try signing in again."
            "code": "refresh_token_reused"
            ERROR codex_core::auth: Failed to refresh token: Your access token could not be refreshed because your refresh token was already used. Please log out and sign in again.
          STDERR
          exit_code: 1
        )
      end

      before do
        user.providers.find_or_create_by!(provider_key: "cursor")
        user.settings.update!(fallback_enabled: true, fallback_providers: [ "cursor" ])
        allow(git_ops).to receive(:head_sha).and_return("pre_agent_sha_abc123")
        allow(container_service).to receive(:execute).and_return(auth_expired_output)
      end

      it "marks the run as auth_expired and does not fall back" do
        expect {
          activity.execute(agent_run_id: agent_run.id)
        }.to raise_error(Temporalio::Error::ApplicationError, /All providers exhausted/)

        agent_run.reload
        expect(agent_run.status).to eq("auth_expired")
        expect(agent_run.auth_provider).to eq("codex")
        expect(agent_run.error_message).to include("refresh_token_reused")
        expect(agent_run.providers_attempted).to contain_exactly(
          hash_including("provider" => "codex", "success" => false, "error_type" => "auth_expired")
        )
        expect(agent_run.provider_switches).to eq(0)
        expect(container_service).to have_received(:execute).once
      end

      it "treats generic refresh failures as ordinary provider errors" do
        generic_refresh_failure = Containers::Provision::Result.failure(
          error: "exit 1",
          stdout: "",
          stderr: "ERROR codex_core::auth: Failed to refresh token: 500 Internal Server Error",
          exit_code: 1
        )
        allow(container_service).to receive(:execute).and_return(generic_refresh_failure, exec_success)
        allow(git_ops).to receive(:commit_uncommitted_changes).and_return(false)
        allow(git_ops).to receive(:has_changes_since?).with("pre_agent_sha_abc123").and_return(false)

        result = activity.execute(agent_run_id: agent_run.id)

        agent_run.reload
        expect(result).to include(success: true, final_provider: "cursor")
        expect(agent_run.status).to eq("running")
        expect(agent_run.providers_attempted).to contain_exactly(
          hash_including("provider" => "codex", "success" => false, "error_type" => "error"),
          hash_including("provider" => "cursor", "success" => true)
        )
        expect(agent_run.provider_switches).to eq(1)
        expect(container_service).to have_received(:execute).twice
      end
    end

    context "when agent times out (wall clock)" do
      before do
        allow(git_ops).to receive(:head_sha).and_return("pre_agent_sha_abc123")
        allow(container_service).to receive(:execute)
          .and_raise(Containers::Provision::TimeoutError)
      end

      it "raises AllProvidersExhausted after timeout" do
        expect {
          activity.execute(agent_run_id: agent_run.id)
        }.to raise_error(Temporalio::Error::ApplicationError, /All providers exhausted/)
      end

      it "marks the agent run as timed out with wall_clock type" do
        begin
          activity.execute(agent_run_id: agent_run.id)
        rescue Temporalio::Error::ApplicationError
          # expected
        end

        agent_run.reload
        expect(agent_run.status).to eq("timeout")
        expect(agent_run.error_message).to include("wall_clock_timeout")
      end

      it "enqueues ProcessRunQueueJob" do
        expect {
          activity.execute(agent_run_id: agent_run.id)
        }.to raise_error(Temporalio::Error::ApplicationError)
          .and have_enqueued_job(ProcessRunQueueJob)
      end

      it "does not enqueue ProcessRunQueueJob when another process finished the run first" do
        allow(container_service).to receive(:execute) do
          agent_run.update!(status: "completed", completed_at: Time.current)
          raise Containers::Provision::TimeoutError
        end

        expect(ProcessRunQueueJob).not_to receive(:perform_later)

        expect {
          activity.execute(agent_run_id: agent_run.id)
        }.to raise_error(Temporalio::Error::ApplicationError)
      end
    end

    context "when agent hits startup timeout" do
      before do
        allow(git_ops).to receive(:head_sha).and_return("pre_agent_sha_abc123")
        allow(container_service).to receive(:execute)
          .and_raise(Containers::Provision::StartupTimeoutError)
      end

      it "marks the agent run as timed out with startup type" do
        begin
          activity.execute(agent_run_id: agent_run.id)
        rescue Temporalio::Error::ApplicationError
          # expected
        end

        agent_run.reload
        expect(agent_run.status).to eq("timeout")
        expect(agent_run.error_message).to include("startup_timeout")
      end

      it "raises AllProvidersExhausted" do
        expect {
          activity.execute(agent_run_id: agent_run.id)
        }.to raise_error(Temporalio::Error::ApplicationError, /All providers exhausted/)
      end
    end

    context "when agent hits idle timeout" do
      before do
        allow(git_ops).to receive(:head_sha).and_return("pre_agent_sha_abc123")
        allow(container_service).to receive(:execute)
          .and_raise(Containers::Provision::IdleTimeoutError)
      end

      it "marks the agent run as timed out with idle type" do
        begin
          activity.execute(agent_run_id: agent_run.id)
        rescue Temporalio::Error::ApplicationError
          # expected
        end

        agent_run.reload
        expect(agent_run.status).to eq("timeout")
        expect(agent_run.error_message).to include("idle_timeout")
      end

      it "raises AllProvidersExhausted" do
        expect {
          activity.execute(agent_run_id: agent_run.id)
        }.to raise_error(Temporalio::Error::ApplicationError, /All providers exhausted/)
      end
    end

    context "when no container is provisioned" do
      it "raises an ApplicationError" do
        other_issue = create(:issue, project: project)
        run_no_container = create(:agent_run, :with_git_context, project: project, issue: other_issue, container_id: nil)
        allow(AgentRun).to receive(:find).with(run_no_container.id).and_return(run_no_container)

        expect {
          activity.execute(agent_run_id: run_no_container.id)
        }.to raise_error(Temporalio::Error::ApplicationError, /No container provisioned/)
      end
    end

    it "raises an error when no prompt is available" do
      agent_run_no_prompt = create(:agent_run, :with_custom_prompt, project: project, container_id: "abc123")
      allow(agent_run_no_prompt).to receive(:effective_prompt).and_return(nil)
      allow(AgentRun).to receive(:find).with(agent_run_no_prompt.id).and_return(agent_run_no_prompt)

      expect {
        activity.execute(agent_run_id: agent_run_no_prompt.id)
      }.to raise_error(Temporalio::Error::ApplicationError, /No prompt available/)
    end

    it "raises ActiveRecord::RecordNotFound for invalid agent_run_id" do
      allow(AgentRun).to receive(:find).and_call_original

      expect {
        activity.execute(agent_run_id: -1)
      }.to raise_error(ActiveRecord::RecordNotFound)
    end

    it "raises for unsupported agent types" do
      unsupported_issue = create(:issue, project: project)
      unsupported_run = create(:agent_run, project: project, issue: unsupported_issue,
        agent_type: "api", container_id: "abc123")
      allow(AgentRun).to receive(:find).with(unsupported_run.id).and_return(unsupported_run)
      allow(Containers::Provision).to receive(:reconnect)
        .with(agent_run: unsupported_run, container_id: "abc123")
        .and_return(container_service)
      allow(Containers::GitOperations).to receive(:new)
        .with(container_service: container_service, agent_run: unsupported_run)
        .and_return(git_ops)
      allow(git_ops).to receive(:head_sha).and_return("sha123")

      expect {
        activity.execute(agent_run_id: unsupported_run.id)
      }.to raise_error(Temporalio::Error::ApplicationError, /All providers exhausted/)
    end

    context "when goal is create_issue" do
      let(:agent_run) do
        create(:agent_run, :create_issue_goal, :with_git_context,
          project: project, container_id: "abc123")
      end

      before do
        allow(container_service).to receive(:execute).and_return(exec_success)
        allow(git_ops).to receive_messages(head_sha: "sha123", commit_uncommitted_changes: false, has_changes_since?: false)
      end

      it "uses the shorter issue goal timeout" do
        expect(container_service).to receive(:execute).with(
          anything,
          hash_including(
            timeout: described_class::DEFAULT_ISSUE_GOAL_TIMEOUT,
            idle_timeout: described_class::DEFAULT_ISSUE_GOAL_IDLE_TIMEOUT
          )
        ).and_return(exec_success)

        activity.execute(agent_run_id: agent_run.id)
      end

      it "includes curl timeouts in the augmented prompt" do
        expect(container_service).to receive(:execute) do |command, **_opts|
          prompt = command.last
          expect(prompt).to include("--connect-timeout 10")
          expect(prompt).to include("--max-time 30")
          exec_success
        end

        activity.execute(agent_run_id: agent_run.id)
      end
    end

    context "when goal is create_pr" do
      it "uses the default agent timeout with create_pr idle_timeout" do
        project.update!(max_execution_seconds: 86_400)
        allow(container_service).to receive(:execute).and_return(exec_success)
        allow(git_ops).to receive_messages(head_sha: "sha123", commit_uncommitted_changes: false, has_changes_since?: false)

        expect(container_service).to receive(:execute).with(
          anything,
          hash_including(
            timeout: AGENT_TIMEOUT_DEFAULT,
            idle_timeout: described_class::DEFAULT_CREATE_PR_IDLE_TIMEOUT
          )
        ).and_return(exec_success)

        activity.execute(agent_run_id: agent_run.id)
      end

      it "does not apply idle timeout to providers without heartbeat support" do
        agent_run.update!(agent_type: "kilocode")
        project.update!(max_execution_seconds: 86_400)
        allow(container_service).to receive(:execute).and_return(exec_success)
        allow(git_ops).to receive_messages(head_sha: "sha123", commit_uncommitted_changes: false, has_changes_since?: false)

        expect(container_service).to receive(:execute).with(
          anything,
          hash_including(
            timeout: AGENT_TIMEOUT_DEFAULT,
            idle_timeout: nil,
            heartbeat_path: nil
          )
        ).and_return(exec_success)

        activity.execute(agent_run_id: agent_run.id)
      end

      it "applies idle timeout and heartbeat path to codex" do
        agent_run.update!(agent_type: "codex")
        project.update!(max_execution_seconds: 86_400)
        allow(container_service).to receive(:execute).and_return(exec_success)
        allow(git_ops).to receive_messages(head_sha: "sha123", commit_uncommitted_changes: false, has_changes_since?: false)

        expect(container_service).to receive(:execute).with(
          anything,
          hash_including(
            timeout: AGENT_TIMEOUT_DEFAULT,
            idle_timeout: described_class::DEFAULT_CREATE_PR_IDLE_TIMEOUT,
            heartbeat_path: File.join(agent_run.worktree_path, ".paid-heartbeat")
          )
        ).and_return(exec_success)

        activity.execute(agent_run_id: agent_run.id)
      end
    end

    context "with fallback enabled" do
      let(:rate_limit_failure) do
        Containers::Provision::Result.failure(
          error: "rate limit", stdout: "", stderr: "rate limit exceeded", exit_code: 1
        )
      end

      before do
        allow(ProviderSupport).to receive(:container_executable_provider_keys).and_return(%w[claude cursor aider])
        user.providers.find_or_create_by!(provider_key: "cursor")
        user.providers.find_or_create_by!(provider_key: "aider")
        user.settings.update!(fallback_enabled: true, fallback_providers: %w[claude cursor aider])
        allow(git_ops).to receive_messages(head_sha: "sha123", commit_uncommitted_changes: false, has_changes_since?: false)
      end

      it "falls back to next provider on rate limit" do
        call_count = 0
        allow(container_service).to receive(:execute) do |_cmd, **_opts|
          call_count += 1
          if call_count == 1
            rate_limit_failure
          else
            exec_success
          end
        end

        result = activity.execute(agent_run_id: agent_run.id)

        expect(result[:success]).to be true
        expect(result[:final_provider]).to eq("cursor")
      end

      it "includes configured fallback-only providers even when saved fallback order is empty" do
        user.providers.find_by!(provider_key: "cursor").update!(
          enabled_for_agent_runs: false,
          enabled_for_fallback: true
        )
        user.settings.update!(fallback_enabled: true, fallback_providers: [])

        call_count = 0
        allow(container_service).to receive(:execute) do |_cmd, **_opts|
          call_count += 1
          if call_count == 1
            rate_limit_failure
          else
            exec_success
          end
        end

        result = activity.execute(agent_run_id: agent_run.id)

        expect(result[:success]).to be true
        expect(result[:final_provider]).to eq("aider")
      end

      it "records provider switch when falling back" do
        call_count = 0
        allow(container_service).to receive(:execute) do |_cmd, **_opts|
          call_count += 1
          if call_count == 1
            rate_limit_failure
          else
            exec_success
          end
        end

        activity.execute(agent_run_id: agent_run.id)

        expect(agent_run.reload.provider_switches).to eq(1)
      end

      # Regression test for the hook-staleness-on-fallback bug
      # (#1163 comment thread): the commit-msg hook is seeded at clone time
      # with the initial provider's trailer. If the agent's first provider
      # hits a rate limit and falls back, intermediate commits made by the
      # fallback provider's agent must carry the *fallback* provider's
      # trailer — not the initial one. Refreshing the trailer file on each
      # provider attempt is how that guarantee is kept.
      it "refreshes the co-author trailer file for each provider attempt so fallback commits get the new trailer" do
        claude = user.providers.find_by!(provider_key: "claude", auth_type: "subscription")
        cursor = user.providers.find_by!(provider_key: "cursor")
        claude.update!(agent_co_author_trailer: "Co-Authored-By: Claude <noreply@anthropic.com>")
        cursor.update!(agent_co_author_trailer: "Co-Authored-By: Cursor <ai@cursor.com>")

        call_count = 0
        allow(container_service).to receive(:execute) do |_cmd, **_opts|
          call_count += 1
          if call_count == 1
            rate_limit_failure
          else
            exec_success
          end
        end

        activity.execute(agent_run_id: agent_run.id)

        # Two provider attempts → two trailer refreshes, in order.
        expect(git_ops).to have_received(:write_co_author_trailer).with(claude).ordered
        expect(git_ops).to have_received(:write_co_author_trailer).with(cursor).ordered
      end

      it "does not refresh the co-author trailer file when the run has no git repo" do
        create_issue_run = create(:agent_run, :create_issue_goal, :with_git_context,
          project: project, issue: issue, container_id: "abc123")
        allow(AgentRun).to receive(:find).with(create_issue_run.id).and_return(create_issue_run)
        allow(Containers::Provision).to receive(:reconnect)
          .with(agent_run: create_issue_run, container_id: "abc123")
          .and_return(container_service)
        allow(Containers::GitOperations).to receive(:new)
          .with(container_service: container_service, agent_run: create_issue_run)
          .and_return(git_ops)

        allow(container_service).to receive(:execute).and_return(exec_success)

        activity.execute(agent_run_id: create_issue_run.id)

        expect(git_ops).not_to have_received(:write_co_author_trailer)
      end

      it "does not continue to the next provider when the first provider times out" do
        allow(container_service).to receive(:execute)
          .and_raise(Containers::Provision::TimeoutError, "took too long")

        expect {
          activity.execute(agent_run_id: agent_run.id)
        }.to raise_error(Temporalio::Error::ApplicationError, /All providers exhausted/)
          .and have_enqueued_job(ProcessRunQueueJob)

        agent_run.reload

        expect(agent_run.status).to eq("timeout")
        expect(agent_run.error_message).to include("wall_clock_timeout")
        expect(agent_run.providers_attempted.map { |attempt| attempt["provider"] }).to eq([ "claude_code" ])
        expect(agent_run.final_provider).to be_nil
      end

      it "reclassifies timeout output that contains quota errors as rate limited" do
        allow(container_service).to receive(:execute) do |_cmd, **_opts|
          agent_run.log!("stderr", "Error: Free tier limit reached. Please upgrade to a paid plan to continue using the service.")
          3.times { |index| agent_run.log!("stdout", "still waiting on provider chunk #{index}") }
          raise Containers::Provision::IdleTimeoutError, "No output received for 300 seconds"
        end

        expect {
          activity.execute(agent_run_id: agent_run.id)
        }.to raise_error(Temporalio::Error::ApplicationError, /All providers exhausted/)

        agent_run.reload
        expect(agent_run.status).to eq("rate_limited")
        expect(agent_run.error_message).to include("rate limited")
        expect(agent_run.providers_attempted.first["error_type"]).to eq("rate_limited")
      end

      it "reclassifies timeout output as rate limited when quota message is within the log scan window" do
        allow(container_service).to receive(:execute) do |_cmd, **_opts|
          agent_run.log!("stderr", "Free tier limit reached. Please upgrade for higher usage.")
          100.times { |index| agent_run.log!("stdout", "provider still warming up: #{index}") }
          raise Containers::Provision::IdleTimeoutError, "No output received for 300 seconds"
        end

        expect {
          activity.execute(agent_run_id: agent_run.id)
        }.to raise_error(Temporalio::Error::ApplicationError, /All providers exhausted/)

        agent_run.reload
        expect(agent_run.status).to eq("rate_limited")
        expect(agent_run.error_message).to include("rate limited")
        expect(agent_run.providers_attempted.first["error_type"]).to eq("rate_limited")
      end

      it "does not reclassify timeout when quota message falls outside the bounded log scan window" do
        allow(container_service).to receive(:execute) do |_cmd, **_opts|
          agent_run.log!("stderr", "Free tier limit reached. Please upgrade for higher usage.")
          250.times { |index| agent_run.log!("stdout", "provider still warming up: #{index}") }
          raise Containers::Provision::IdleTimeoutError, "No output received for 300 seconds"
        end

        expect {
          activity.execute(agent_run_id: agent_run.id)
        }.to raise_error(Temporalio::Error::ApplicationError, /All providers exhausted/)
          .and have_enqueued_job(ProcessRunQueueJob)

        agent_run.reload
        expect(agent_run.status).to eq("timeout")
        expect(agent_run.providers_attempted.first["error_type"]).to eq("timeout")
      end

      it "reclassifies timeout output as rate limited when the quota signal spans chunk boundaries" do
        allow(container_service).to receive(:execute) do |_cmd, **_opts|
          agent_run.log!("stderr", "Free tier")
          agent_run.log!("stderr", " limit reached while processing request")
          raise Containers::Provision::IdleTimeoutError, "No output received for 300 seconds"
        end

        expect {
          activity.execute(agent_run_id: agent_run.id)
        }.to raise_error(Temporalio::Error::ApplicationError, /All providers exhausted/)

        agent_run.reload
        expect(agent_run.status).to eq("rate_limited")
        expect(agent_run.error_message).to include("rate limited")
        expect(agent_run.providers_attempted.first["error_type"]).to eq("rate_limited")
      end

      it "reclassifies timeout output as rate limited when HTTP 429 appears in output" do
        allow(container_service).to receive(:execute) do |_cmd, **_opts|
          agent_run.log!("stderr", "Error: HTTP 429 Too Many Requests")
          raise Containers::Provision::IdleTimeoutError, "No output received for 300 seconds"
        end

        expect {
          activity.execute(agent_run_id: agent_run.id)
        }.to raise_error(Temporalio::Error::ApplicationError, /All providers exhausted/)

        agent_run.reload
        expect(agent_run.status).to eq("rate_limited")
        expect(agent_run.providers_attempted.first["error_type"]).to eq("rate_limited")
      end

      it "reclassifies timeout output as rate limited when 'too many requests' appears with 429 context" do
        allow(container_service).to receive(:execute) do |_cmd, **_opts|
          agent_run.log!("stderr", "Error 429: Too many requests. Please retry after 60 seconds.")
          raise Containers::Provision::IdleTimeoutError, "No output received for 300 seconds"
        end

        expect {
          activity.execute(agent_run_id: agent_run.id)
        }.to raise_error(Temporalio::Error::ApplicationError, /All providers exhausted/)

        agent_run.reload
        expect(agent_run.status).to eq("rate_limited")
        expect(agent_run.providers_attempted.first["error_type"]).to eq("rate_limited")
      end

      it "does not reclassify timeouts when recent output only mentions rate limits conversationally" do
        allow(container_service).to receive(:execute) do |_cmd, **_opts|
          agent_run.log!("stdout", "Document how to handle a service overloaded response and a server at capacity banner in the retry guide.")
          raise Containers::Provision::IdleTimeoutError, "No output received for 300 seconds"
        end

        expect {
          activity.execute(agent_run_id: agent_run.id)
        }.to raise_error(Temporalio::Error::ApplicationError, /All providers exhausted/)
          .and have_enqueued_job(ProcessRunQueueJob)

        agent_run.reload
        expect(agent_run.status).to eq("timeout")
        expect(agent_run.error_message).to include("idle_timeout")
        expect(agent_run.providers_attempted.first["error_type"]).to eq("timeout")
      end

      it "does not reclassify timeouts when 'too many requests' appears without 429 context" do
        allow(container_service).to receive(:execute) do |_cmd, **_opts|
          agent_run.log!("stdout", "You have sent too many requests in a given amount of time.")
          raise Containers::Provision::IdleTimeoutError, "No output received for 300 seconds"
        end

        expect {
          activity.execute(agent_run_id: agent_run.id)
        }.to raise_error(Temporalio::Error::ApplicationError, /All providers exhausted/)
          .and have_enqueued_job(ProcessRunQueueJob)

        agent_run.reload
        expect(agent_run.status).to eq("timeout")
        expect(agent_run.error_message).to include("idle_timeout")
        expect(agent_run.providers_attempted.first["error_type"]).to eq("timeout")
      end

      it "classifies OutputAbortError from quota patterns as rate_limited instead of timeout" do
        allow(container_service).to receive(:execute).and_raise(
          Containers::Provision::OutputAbortError.new(
            "Process aborted: fatal output pattern detected",
            matched_output: "Error: Free tier limit reached. Please upgrade to a paid plan."
          )
        )

        expect {
          activity.execute(agent_run_id: agent_run.id)
        }.to raise_error(Temporalio::Error::ApplicationError, /All providers exhausted/)

        agent_run.reload
        expect(agent_run.status).to eq("rate_limited")
        expect(agent_run.error_message).to include("rate limited")
        expect(agent_run.providers_attempted.first["error_type"]).to eq("rate_limited")
      end

      it "preserves timeout handling when the timeout happens before provider execution starts" do
        allow(activity).to receive(:augment_prompt_for_goal)
          .and_raise(Containers::Provision::TimeoutError, "took too long before exec")

        expect {
          activity.execute(agent_run_id: agent_run.id)
        }.to raise_error(Temporalio::Error::ApplicationError, /All providers exhausted/)
          .and have_enqueued_job(ProcessRunQueueJob)

        agent_run.reload
        expect(agent_run.status).to eq("timeout")
        expect(agent_run.error_message).to include("wall_clock_timeout")
      end

      it "raises AllProvidersExhausted when all fallbacks fail" do
        allow(container_service).to receive(:execute).and_return(exec_failure)

        expect {
          activity.execute(agent_run_id: agent_run.id)
        }.to raise_error(Temporalio::Error::ApplicationError, /All providers exhausted/)
      end

      it "marks run as rate_limited when all providers hit rate limits" do
        allow(container_service).to receive(:execute).and_return(rate_limit_failure)

        expect {
          activity.execute(agent_run_id: agent_run.id)
        }.to raise_error(Temporalio::Error::ApplicationError, /All providers exhausted/)

        agent_run.reload
        expect(agent_run.status).to eq("rate_limited")
        expect(agent_run.error_message).to include("rate limited")
      end

      it "classifies 'exhausted ... capacity' as a rate limit" do
        gemini_rate_limit = Containers::Provision::Result.failure(
          error: "exit 1", stdout: "", stderr: "You have exhausted your capacity on this model.", exit_code: 1
        )
        allow(container_service).to receive(:execute).and_return(gemini_rate_limit)

        expect {
          activity.execute(agent_run_id: agent_run.id)
        }.to raise_error(Temporalio::Error::ApplicationError, /All providers exhausted/)

        agent_run.reload
        expect(agent_run.status).to eq("rate_limited")
        expect(agent_run.error_message).to include("rate limited")
        expect(agent_run.rate_limited_until).to be_present
      end

      it "executes a rate-limit fallback entry for the same provider key" do
        fallback_provider = create_claude_rate_limit_fallback_provider

        expect_same_provider_rate_limit_fallback_execution(fallback_provider)
      end

      it "executes a rate-limit fallback entry even when enabled_for_agent_runs is false" do
        fallback_provider = create_claude_rate_limit_fallback_provider
        fallback_provider.update!(enabled_for_agent_runs: false)

        expect_same_provider_rate_limit_fallback_execution(fallback_provider)
      end

      it "skips a rate-limit fallback entry whose ProviderState is already rate limited" do
        fallback_provider = create_claude_rate_limit_fallback_provider
        fallback_provider.user.provider_states.find_or_create_by!(provider_name: fallback_provider.routing_key).update!(
          rate_limited_until: 2.hours.from_now
        )
        user.settings.update!(fallback_enabled: true, fallback_providers: [ "claude" ])
        execute_calls = []

        allow(container_service).to receive(:execute) do |command, **opts|
          execute_calls << [ command, opts ]
          execute_calls.one? ? rate_limit_failure : exec_success
        end

        result = activity.execute(agent_run_id: agent_run.id)

        agent_run.reload
        expect(result[:success]).to be true
        expect(agent_run.providers_attempted).to include(
          include("provider" => "claude_code", "error_type" => "rate_limited"),
          include("provider" => fallback_provider.routing_key, "error_type" => "rate_limited")
        )
        expect(execute_calls.any? { |_command, opts| opts[:env].value?("sk-fallback-secret") }).to be(false)
      end

      it "uses provider display names in exhausted-provider labels" do
        api_key = create(:provider_api_key, user: user, api_service_type: "openrouter")
        kimi = create_opencode_provider_entry(user: user, api_key: api_key, name: "Kimi K2.5", model: "moonshotai/kimi-k2-0905")
        opus = create_opencode_provider_entry(user: user, api_key: api_key, name: "Opus via OpenCode", model: "anthropic/claude-opus-4.1")

        labels = activity.send(:provider_attempt_labels, [ kimi.routing_key, opus.routing_key ], agent_run, user)

        expect(labels).to eq([ "Kimi K2.5", "Opus via OpenCode" ])
      end

      it "executes routing-key fallbacks with the provider entry config intact" do
        allow(ProviderSupport).to receive(:container_executable_provider_keys).and_return(%w[claude cursor aider opencode])
        api_key = create(:provider_api_key, user: user, api_service_type: "openrouter", api_key: "sk-openrouter-secret")
        opencode_provider = create_opencode_provider_entry(
          user: user,
          api_key: api_key,
          name: "Kimi K2.5",
          model: "moonshotai/kimi-k2-0905"
        )
        user.settings.update!(fallback_enabled: true, fallback_providers: [ opencode_provider.routing_key ])

        expect_opencode_fallback_execution(opencode_provider)
      end

      it "marks run as rate_limited when all providers are already rate limited in ProviderState" do
        reset_time = 2.hours.from_now

        # Pre-set all provider states as rate limited so provider_unavailable? skips them
        %w[claude cursor aider].each do |provider_name|
          user.provider_states.find_or_create_by!(provider_name: provider_name).tap do |state|
            state.update!(rate_limited_until: reset_time)
          end
        end

        # No container execution should occur since all providers are skipped
        expect(container_service).not_to receive(:execute)

        expect {
          activity.execute(agent_run_id: agent_run.id)
        }.to raise_error(Temporalio::Error::ApplicationError, /All providers exhausted/)

        agent_run.reload
        expect(agent_run.status).to eq("rate_limited")
        expect(agent_run.error_message).to include("rate limited")
        expect(agent_run.rate_limited_until).to be_present
      end

      it "preserves timeout status when timeout is followed by other failures" do
        call_count = 0
        allow(container_service).to receive(:execute) do |_cmd, **_opts|
          call_count += 1
          if call_count == 1
            raise Containers::Provision::TimeoutError, "took too long"
          else
            exec_failure
          end
        end

        expect {
          activity.execute(agent_run_id: agent_run.id)
        }.to raise_error(Temporalio::Error::ApplicationError, /All providers exhausted/)
          .and have_enqueued_job(ProcessRunQueueJob)

        agent_run.reload
        expect(agent_run.status).to eq("timeout")
        expect(agent_run.error_message).to include("wall_clock_timeout")
      end
    end

    context "when resolving user settings" do
      it "resolves user settings from project creator" do
        allow(container_service).to receive(:execute).and_return(exec_success)
        allow(git_ops).to receive_messages(head_sha: "sha123", commit_uncommitted_changes: false, has_changes_since?: false)

        result = activity.execute(agent_run_id: agent_run.id)

        expect(result[:success]).to be true
      end

      it "raises MissingUser when no user is available" do
        orphan_account = create(:account)
        orphan_token = create(:github_token, :without_creator, account: orphan_account)
        project_without_creator = create(:project, :without_creator, account: orphan_account, github_token: orphan_token)
        issue_for_orphan = create(:issue, project: project_without_creator)
        orphan_run = create(:agent_run, :with_git_context, project: project_without_creator,
          issue: issue_for_orphan, container_id: "abc123")
        allow(AgentRun).to receive(:find).with(orphan_run.id).and_return(orphan_run)
        allow(orphan_token).to receive(:client).and_return(instance_double(GithubClient, issue_comments: []))

        expect {
          activity.execute(agent_run_id: orphan_run.id)
        }.to raise_error(Temporalio::Error::ApplicationError, /No user available/)
      end
    end
  end

  describe "max_execution_seconds enforcement" do
    before do
      allow(container_service).to receive(:execute).and_return(exec_success)
      allow(git_ops).to receive_messages(head_sha: "sha123", commit_uncommitted_changes: false, has_changes_since?: false)
    end

    it "caps effective_timeout by remaining execution time" do
      project.update!(max_execution_seconds: 600)
      agent_run.update!(started_at: 5.minutes.ago, status: "running")

      expect(container_service).to receive(:execute).with(
        anything,
        hash_including(timeout: a_value <= 300)
      ).and_return(exec_success)

      activity.execute(agent_run_id: agent_run.id)
    end

    it "pauses when execution time limit is exceeded" do
      project.update!(max_execution_seconds: 60)
      agent_run.update!(started_at: 2.minutes.ago, status: "running")

      allow(AgentRuns::Cancel).to receive(:call)

      result = activity.execute(agent_run_id: agent_run.id)

      agent_run.reload
      expect(result).to include(success: false, paused: true, agent_run_id: agent_run.id)
      expect(agent_run.status).to eq("paused")
      expect(agent_run.guardrail_violation_type).to eq("time_limit")
      expect(AgentRuns::Cancel).to have_received(:call).with(agent_run: agent_run, skip_status_update: true)
    end

    it "returns a paused result when the run was already paused by another guardrail" do
      project.update!(max_execution_seconds: 60)
      agent_run.update!(started_at: 2.minutes.ago, status: "running")

      violation_result = instance_double(Guardrails::ViolationHandler::Result, paused?: false)
      allow(Guardrails::ViolationHandler).to receive(:call) do
        agent_run.update!(status: "paused", paused_at: Time.current, guardrail_violation_type: "cost_limit")
        violation_result
      end

      result = activity.execute(agent_run_id: agent_run.id)

      agent_run.reload
      expect(result).to include(success: false, paused: true, agent_run_id: agent_run.id)
      expect(agent_run.status).to eq("paused")
      expect(agent_run.guardrail_violation_type).to eq("cost_limit")
    end
  end

  describe "loop guardrail handling" do
    before do
      allow(container_service).to receive(:execute).and_return(exec_success)
      allow(git_ops).to receive_messages(head_sha: "sha123", commit_uncommitted_changes: false, has_changes_since?: false)
    end

    it "returns a paused result when the run was already paused during loop handling" do
      allow(activity).to receive(:run_agent_with_provider).and_raise(described_class::InfiniteLoopError, "loop detected")

      violation_result = instance_double(Guardrails::ViolationHandler::Result, paused?: false)
      allow(Guardrails::ViolationHandler).to receive(:call) do
        agent_run.update!(status: "paused", paused_at: Time.current, guardrail_violation_type: "cost_limit")
        violation_result
      end

      result = activity.execute(agent_run_id: agent_run.id)

      agent_run.reload
      expect(result).to include(success: false, paused: true, agent_run_id: agent_run.id)
      expect(agent_run.status).to eq("paused")
      expect(agent_run.guardrail_violation_type).to eq("cost_limit")
    end
  end

  describe "#rate_limit_reset_at" do
    let(:harness_provider) { double(parse_rate_limit_reset: 1.hour.ago) }

    before do
      allow(ProviderSupport).to receive(:provider_key_for_agent_type).with("claude_code").and_return("claude")
      allow(ProviderSupport).to receive(:harness_provider_key_for).with("claude").and_return("claude")
      allow(AgentHarness).to receive(:provider).with(:claude).and_return(harness_provider)
    end

    it "falls back when agent-harness parses a stale reset time" do
      freeze_time do
        reset_at = activity.send(:rate_limit_reset_at, "claude_code", "Rate limit exceeded. Reset at: 1")

        expect(reset_at).to eq(1.hour.from_now)
      end
    end
  end

  describe "paused run protection after provider exhaustion" do
    before do
      allow(container_service).to receive(:execute).and_return(exec_failure)
      allow(git_ops).to receive_messages(head_sha: "sha123", commit_uncommitted_changes: false, has_changes_since?: false)
    end

    it "preserves paused state when a guardrail paused the run during provider execution" do
      # Simulate a cost budget guardrail pausing the run during execution
      allow(container_service).to receive(:execute) do
        agent_run.update!(status: "paused", paused_at: Time.current, guardrail_violation_type: "cost_limit")
        exec_failure
      end

      result = activity.execute(agent_run_id: agent_run.id)

      agent_run.reload
      expect(result).to include(success: false, paused: true, agent_run_id: agent_run.id)
      expect(agent_run.status).to eq("paused")
      expect(agent_run.guardrail_violation_type).to eq("cost_limit")
    end
  end
end
