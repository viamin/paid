# frozen_string_literal: true

require "rails_helper"
require "ostruct"

RSpec.describe Activities::CreateAgentRunActivity do
  let(:activity) { described_class.new }
  let(:project) { create(:project) }
  let(:issue) { create(:issue, project: project) }
  let(:claude_provider) { project.created_by.providers.find_by!(provider_key: "claude") }
  let(:codex_provider) { create(:provider, user: project.created_by, provider_key: "codex") }

  before do
    # Stub conversation_section_for so the activity does not make real HTTP
    # calls to fetch issue comments (blocked by WebMock). Individual tests
    # that exercise conversation section behavior override this stub.
    allow(Prompts::BuildForIssue).to receive(:conversation_section_for).and_return("")
  end

  describe "#execute" do
    it "creates an agent run for the project and issue" do
      result = activity.execute(project_id: project.id, issue_id: issue.id)

      expect(result[:agent_run_id]).to be_present
      expect(result[:provider_attempt_count]).to eq(1)
      agent_run = AgentRun.find(result[:agent_run_id])
      expect(agent_run.project).to eq(project)
      expect(agent_run.issue).to eq(issue)
      expect(agent_run.status).to eq("queued")
      expect(agent_run.agent_type).to eq("claude_code")
      expect(agent_run.configuration_bundle).to be_present
    end

    it "returns the project max_execution_seconds in the result" do
      project.update!(max_execution_seconds: 900)
      result = activity.execute(project_id: project.id, issue_id: issue.id)

      expect(result[:max_execution_seconds]).to eq(900)
    end

    it "returns default max_execution_seconds when not customized" do
      result = activity.execute(project_id: project.id, issue_id: issue.id)

      expect(result[:max_execution_seconds]).to eq(3600)
    end

    it "returns the user override for max_execution_seconds when set" do
      project.update!(max_execution_seconds: 900)
      project.created_by.settings.update!(max_execution_seconds: 1800)

      result = activity.execute(project_id: project.id, issue_id: issue.id)

      expect(result[:max_execution_seconds]).to eq(1800)
    end

    it "accepts a custom agent_type" do
      result = activity.execute(project_id: project.id, issue_id: issue.id, agent_type: "aider")

      agent_run = AgentRun.find(result[:agent_run_id])
      expect(agent_run.agent_type).to eq("aider")
      expect(result[:provider_attempt_count]).to eq(1)
    end

    it "accepts copilot as a container-executable agent_type" do
      result = activity.execute(project_id: project.id, issue_id: issue.id, agent_type: "copilot")

      agent_run = AgentRun.find(result[:agent_run_id])
      expect(agent_run.agent_type).to eq("copilot")
      expect(result[:provider_attempt_count]).to eq(1)
    end

    it "derives agent_type from provider_id when only a provider is supplied" do
      provider = create(:provider, user: project.created_by, provider_key: "cursor")

      result = activity.execute(project_id: project.id, issue_id: issue.id, provider_id: provider.id)

      agent_run = AgentRun.find(result[:agent_run_id])
      expect(agent_run.provider).to eq(provider)
      expect(agent_run.agent_type).to eq("cursor")
    end

    it "records the provider selection decision with requested and ranked alternatives" do
      provider = create(:provider, user: project.created_by, provider_key: "cursor")

      result = activity.execute(project_id: project.id, issue_id: issue.id, provider_id: provider.id)

      agent_run = AgentRun.find(result[:agent_run_id])
      decision = agent_run.orchestration_decisions.where(decision_type: "select_agent").find_by(actor: "requested_provider")

      expect_requested_provider_decision(
        decision: decision,
        provider_id: provider.id,
        provider_key: "cursor",
        agent_type: "cursor"
      )
    end

    it "falls back to the runnable default when a requested provider_id is not container executable" do
      provider = create(:provider, user: project.created_by, provider_key: "copilot")
      allow(ProviderSupport).to receive(:container_executable_provider_key?).and_call_original
      allow(ProviderSupport).to receive(:container_executable_provider_key?).with("copilot").and_return(false)

      result = activity.execute(project_id: project.id, issue_id: issue.id, provider_id: provider.id)

      agent_run = AgentRun.find(result[:agent_run_id])
      expect(agent_run.provider).to eq(project.created_by.providers.find_by!(provider_key: "claude"))
      expect(agent_run.agent_type).to eq("claude_code")
    end

    it "persists the goal when provided" do
      result = activity.execute(
        project_id: project.id,
        issue_id: issue.id,
        goal: "review",
        source_pull_request_number: 42
      )

      agent_run = AgentRun.find(result[:agent_run_id])
      expect(agent_run.goal).to eq("review")
    end

    it "uses the configured primary provider when agent type is omitted" do
      codex_provider = create(:provider, user: project.created_by, provider_key: "codex")
      project.created_by.settings.update!(default_agent_provider: codex_provider.routing_key)

      result = activity.execute(project_id: project.id, issue_id: issue.id)

      agent_run = AgentRun.find(result[:agent_run_id])
      expect(agent_run.provider).to eq(codex_provider)
      expect(agent_run.agent_type).to eq("codex")
    end

    it "fails fast when a selected provider is disabled for agent runs" do
      codex_provider = create(:provider, user: project.created_by, provider_key: "codex")
      codex_provider.update!(enabled_for_agent_runs: false)

      expect {
        activity.execute(project_id: project.id, issue_id: issue.id, provider_id: codex_provider.id)
      }.to raise_error(Temporalio::Error::ApplicationError) { |error|
        expect(error.type).to eq("NoRunnableProvider")
        expect(error.non_retryable).to be(true)
      }
    end

    it "fails fast when an explicit provider_id no longer resolves" do
      missing_provider_id = create(:provider, user: project.created_by, provider_key: "cursor").id
      Provider.find(missing_provider_id).destroy!

      expect {
        activity.execute(
          project_id: project.id,
          issue_id: issue.id,
          provider_id: missing_provider_id,
          agent_type: "claude_code"
        )
      }.to raise_error(Temporalio::Error::ApplicationError) { |error|
        expect(error.type).to eq("NoRunnableProvider")
        expect(error.non_retryable).to be(true)
      }

      decision = project.orchestration_decisions.order(:id).last

      expect_failed_provider_decision(decision: decision, provider_id: missing_provider_id)
    end

    it "uses the goal-specific provider for fresh review runs" do
      codex_provider = create(:provider, user: project.created_by, provider_key: "codex")
      project.created_by.settings.update!(default_agent_providers_by_goal: { "review" => codex_provider.routing_key })

      result = activity.execute(
        project_id: project.id,
        issue_id: issue.id,
        goal: "review",
        source_pull_request_number: 42
      )

      agent_run = AgentRun.find(result[:agent_run_id])
      expect(agent_run.provider).to eq(codex_provider)
      expect(agent_run.agent_type).to eq("codex")
    end

    it "refreshes automatic runs to the goal-specific default provider on resume" do
      codex_provider = create(:provider, user: project.created_by, provider_key: "codex")
      queued_run = create(
        :agent_run,
        :queued,
        project: project,
        issue: issue,
        source_pull_request_number: 42,
        trigger_type: "automatic",
        goal: "review"
      )
      project.created_by.settings.update!(default_agent_providers_by_goal: { "review" => codex_provider.routing_key })

      result = activity.execute(agent_run_id: queued_run.id)

      agent_run = AgentRun.find(result[:agent_run_id])
      expect(agent_run.provider).to eq(codex_provider)
      expect(agent_run.agent_type).to eq("codex")
      expect(agent_run.status).to eq("queued")
      expect(agent_run.configuration_bundle.definition).to include(
        "provider_id" => codex_provider.id,
        "agent_type" => "codex"
      )
    end

    it "preserves the existing configuration bundle on resume when provider selection is unchanged" do
      existing_bundle = create(:configuration_bundle,
        account: project.account,
        definition: existing_create_pr_bundle_definition)
      queued_run = create(:agent_run,
        :queued,
        project: project,
        issue: issue,
        provider: claude_provider,
        agent_type: "claude_code",
        configuration_bundle: existing_bundle)

      activity.execute(agent_run_id: queued_run.id)

      expect(queued_run.reload.configuration_bundle).to eq(existing_bundle)
    end

    it "recomputes the configuration bundle on resume when automatic provider selection changes" do
      existing_bundle = create(:configuration_bundle,
        account: project.account,
        definition: existing_review_bundle_definition)
      queued_run = create_review_run_with_bundle(existing_bundle)
      project.created_by.settings.update!(default_agent_providers_by_goal: { "review" => codex_provider.routing_key })

      activity.execute(agent_run_id: queued_run.id)

      queued_run.reload
      expect(queued_run.provider).to eq(codex_provider)
      expect(queued_run.agent_type).to eq("codex")
      expect(queued_run.configuration_bundle).not_to eq(existing_bundle)
      expect(queued_run.configuration_bundle.definition).to include(
        "provider_id" => codex_provider.id,
        "agent_type" => "codex"
      )
    end

    def existing_review_bundle_definition
      {
        "schema_version" => 1,
        "goal" => "review",
        "agent_type" => "claude_code",
        "provider_id" => claude_provider.id
      }
    end

    def existing_create_pr_bundle_definition
      {
        "schema_version" => 1,
        "goal" => "create_pr",
        "agent_type" => "claude_code",
        "provider_id" => claude_provider.id,
        "experiments" => {}
      }
    end

    def create_review_run_with_bundle(bundle)
      create(:agent_run,
        :queued,
        :automatic,
        project: project,
        issue: issue,
        source_pull_request_number: 42,
        goal: "review",
        provider: claude_provider,
        agent_type: "claude_code",
        configuration_bundle: bundle)
    end

    it "fails fast when a resumed queued run refreshes to a provider now disabled for agent runs" do
      codex_provider = create(:provider, user: project.created_by, provider_key: "codex")
      claude_provider = project.created_by.providers.find_by!(provider_key: "claude")
      queued_run = create(:agent_run, :queued, :automatic,
        project: project, issue: issue, provider: claude_provider, agent_type: "claude_code")
      codex_provider.update!(enabled_for_agent_runs: false)
      allow(activity).to receive(:resolve_provider_selection).and_return([ codex_provider.id, "codex" ])

      expect {
        activity.execute(agent_run_id: queued_run.id)
      }.to raise_error(Temporalio::Error::ApplicationError) { |error|
        expect(error.type).to eq("NoRunnableProvider")
        expect(error.non_retryable).to be(true)
      }

      expect(queued_run.reload.provider).to eq(claude_provider)
      expect(queued_run.agent_type).to eq("claude_code")
      expect(queued_run.status).to eq("queued")
    end

    it "persists draft review round tracking metadata when provided" do
      result = activity.execute(
        project_id: project.id,
        issue_id: issue.id,
        count_toward_draft_review_round: true,
        expected_draft_review_count: 3
      )

      agent_run = AgentRun.find(result[:agent_run_id])
      expect(agent_run.count_toward_draft_review_round).to be(true)
      expect(agent_run.expected_draft_review_count).to eq(3)
    end

    it "requires expected_draft_review_count when tracking draft review rounds" do
      expect {
        activity.execute(
          project_id: project.id,
          issue_id: issue.id,
          count_toward_draft_review_round: true
        )
      }.to raise_error(ActiveRecord::RecordInvalid, /Expected draft review count is required/)
    end

    it "defaults goal to create_pr when not provided" do
      result = activity.execute(project_id: project.id, issue_id: issue.id)

      agent_run = AgentRun.find(result[:agent_run_id])
      expect(agent_run.goal).to eq("create_pr")
    end

    it "returns deduplicated provider_attempt_count when fallback is enabled" do
      allow(ProviderSupport).to receive(:container_executable_provider_keys).and_return(%w[claude cursor aider])
      project.created_by.providers.find_or_create_by!(provider_key: "cursor")
      project.created_by.providers.find_or_create_by!(provider_key: "aider")
      project.created_by.settings.update!(fallback_enabled: true, fallback_providers: %w[claude cursor aider])

      result = activity.execute(project_id: project.id, issue_id: issue.id, agent_type: "claude_code")

      expect(result[:provider_attempt_count]).to eq(3)
    end

    it "counts configured fallback-only providers even when not explicitly ordered yet" do
      allow(ProviderSupport).to receive(:container_executable_provider_keys).and_return(%w[claude cursor aider])
      project.created_by.providers.find_or_create_by!(
        provider_key: "cursor",
        enabled_for_agent_runs: false,
        enabled_for_fallback: true
      )
      project.created_by.settings.update!(fallback_enabled: true, fallback_providers: [])

      result = activity.execute(project_id: project.id, issue_id: issue.id, agent_type: "claude_code")

      expect(result[:provider_attempt_count]).to eq(2)
    end

    it "returns one attempt for an explicitly selected provider when fallback is disabled" do
      provider = create(:provider, user: project.created_by, provider_key: "cursor")
      project.created_by.settings.update!(fallback_enabled: false, fallback_providers: [ provider.routing_key ])

      result = activity.execute(project_id: project.id, issue_id: issue.id, provider_id: provider.id, agent_type: "cursor")

      expect(result[:provider_attempt_count]).to eq(1)
    end

    it "counts fallbacks for an explicitly selected provider only when fallback is enabled" do
      primary_provider = create(:provider, user: project.created_by, provider_key: "cursor")
      fallback_provider = create(:provider, user: project.created_by, provider_key: "aider")
      project.created_by.providers.find_by!(provider_key: "claude").update!(enabled_for_fallback: false)
      project.created_by.settings.update!(fallback_enabled: true, fallback_providers: [ fallback_provider.routing_key ])

      result = activity.execute(project_id: project.id, issue_id: issue.id, provider_id: primary_provider.id, agent_type: "cursor")

      expect(result[:provider_attempt_count]).to eq(2)
    end

    it "includes rate-limit fallback entries in provider_attempt_count" do
      allow(ProviderSupport).to receive(:container_executable_provider_keys).and_return(%w[claude cursor])
      api_key = create(:provider_api_key, user: project.created_by, api_service_type: "anthropic")
      project.created_by.providers.create!(
        provider_key: "claude",
        auth_type: "api_key",
        provider_api_key: api_key,
        fallback_role: "rate_limit_fallback",
        enabled_for_agent_runs: false,
        enabled_for_fallback: true
      )
      project.created_by.providers.find_or_create_by!(provider_key: "cursor")
      project.created_by.settings.update!(fallback_enabled: true, fallback_providers: [ "cursor" ])

      result = activity.execute(project_id: project.id, issue_id: issue.id, agent_type: "claude_code")

      expect(result[:provider_attempt_count]).to eq(3)
    end

    it "warns when the selected provider is already rate limited" do
      logger = instance_spy(Logger, info: nil, warn: nil)
      allow(activity).to receive(:logger).and_return(logger)

      create(
        :provider_state,
        :rate_limited,
        user: project.created_by,
        provider_name: "claude"
      )

      activity.execute(project_id: project.id, issue_id: issue.id)

      expect(logger).to have_received(:warn).with(
        hash_including(
          message: "agent_execution.selected_provider_rate_limited",
          project_id: project.id,
          provider_key: "claude",
          provider_state_name: "claude",
          agent_type: "claude_code",
          goal: "create_pr"
        )
      )
    end

    it "updates the issue paid_state to in_progress" do
      activity.execute(project_id: project.id, issue_id: issue.id)

      expect(issue.reload.paid_state).to eq("in_progress")
    end

    it "records create_agent_run phase starting at the run creation time" do
      result = activity.execute(project_id: project.id, issue_id: issue.id)

      agent_run = AgentRun.find(result[:agent_run_id])
      phase = AgentRunPhase.order(:id).last

      expect(phase.phase_key).to eq("create_agent_run")
      expect(phase.started_at.to_i).to eq(agent_run.created_at.to_i)
      expect(phase.started_at).to be >= agent_run.created_at
    end

    it "does not fail when phase recording raises" do
      allow(AgentRunPhase).to receive(:record!).and_raise(StandardError, "phase write failed")
      result = nil

      expect {
        result = activity.execute(project_id: project.id, issue_id: issue.id)
      }.not_to raise_error

      expect(AgentRun.find(result[:agent_run_id]).status).to eq("queued")
      expect(issue.reload.paid_state).to eq("in_progress")
    end

    it "does not fail when model selection raises" do
      allow(Models::Select).to receive(:call).and_raise(StandardError, "selection blew up")
      result = nil

      expect {
        result = activity.execute(project_id: project.id, issue_id: issue.id)
      }.not_to raise_error

      agent_run = AgentRun.find(result[:agent_run_id])
      expect(agent_run.status).to eq("queued")
      expect(agent_run.model_selection).to be_nil
      expect(issue.reload.paid_state).to eq("in_progress")
    end

    it "records a failed phase when later side effects raise" do
      allow(Issue).to receive(:find).with(issue.id).and_return(issue)
      allow(issue).to receive(:update!).and_raise(StandardError, "issue update failed")

      expect {
        activity.execute(project_id: project.id, issue_id: issue.id)
      }.to raise_error(StandardError, "issue update failed")

      phase = AgentRunPhase.order(:id).last
      expect(phase.phase_key).to eq("create_agent_run")
      expect(phase.status).to eq("failed")
      expect(phase.metadata["error_class"]).to eq("StandardError")
    end

    it "raises ActiveRecord::RecordNotFound for invalid project_id" do
      expect {
        activity.execute(project_id: -1, issue_id: issue.id)
      }.to raise_error(ActiveRecord::RecordNotFound)
    end

    it "raises ActiveRecord::RecordNotFound for invalid issue_id" do
      expect {
        activity.execute(project_id: project.id, issue_id: -1)
      }.to raise_error(ActiveRecord::RecordNotFound)
    end

    context "with prompt versioning" do
      let!(:prompt) do
        Prompt.find_by(slug: "coding.issue_implementation")&.destroy!
        p = create(:prompt, :global, slug: "coding.issue_implementation")
        p.create_version!(
          template: <<~'TEMPLATE'
            Work on {{title}} (#{{issue_number}})

            {{body}}

            Test: {{test_command}}
            Lint: {{lint_command}}
          TEMPLATE
        )
        p
      end

      it "resolves and renders prompt version when no custom_prompt is provided" do
        result = activity.execute(project_id: project.id, issue_id: issue.id)

        agent_run = AgentRun.find(result[:agent_run_id])
        expect(agent_run.prompt_version).to eq(prompt.current_version)
        expect(agent_run.custom_prompt).to include(issue.title)
        expect(agent_run.custom_prompt).to include(issue.github_number.to_s)
      end

      it "renders template with correct variables" do
        result = activity.execute(project_id: project.id, issue_id: issue.id)

        agent_run = AgentRun.find(result[:agent_run_id])
        expect(agent_run.custom_prompt).to include("Test: bundle exec rspec")
        expect(agent_run.custom_prompt).to include("Lint: bundle exec rubocop")
      end

      it "does not assign prompt_version when custom_prompt is provided" do
        result = activity.execute(
          project_id: project.id,
          issue_id: issue.id,
          custom_prompt: "Do something custom"
        )

        agent_run = AgentRun.find(result[:agent_run_id])
        expect(agent_run.prompt_version).to be_nil
        expect(agent_run.custom_prompt).to eq("Do something custom")
      end

      it "does not assign prompt_version when no issue is present" do
        result = activity.execute(
          project_id: project.id,
          issue_id: nil,
          custom_prompt: "No issue prompt"
        )

        agent_run = AgentRun.find(result[:agent_run_id])
        expect(agent_run.prompt_version).to be_nil
        expect(agent_run.custom_prompt).to eq("No issue prompt")
      end

      it "handles nil when Prompts::Resolve returns nil" do
        prompt.update!(active: false)

        result = activity.execute(project_id: project.id, issue_id: issue.id)

        agent_run = AgentRun.find(result[:agent_run_id])
        expect(agent_run.prompt_version).to be_nil
        expect(agent_run.custom_prompt).to be_nil
      end

      it "does not use prompt version when issue is untrusted" do
        untrusted_issue = create(:issue, project: project, github_creator_login: "untrusted-user")

        result = activity.execute(project_id: project.id, issue_id: untrusted_issue.id)

        agent_run = AgentRun.find(result[:agent_run_id])
        expect(agent_run.prompt_version).to be_nil
        expect(agent_run.custom_prompt).to be_nil
      end

      it "appends trusted issue comments to the rendered custom_prompt" do
        trusted_login = project.allowed_github_usernames.first
        comment = OpenStruct.new(
          user: OpenStruct.new(login: trusted_login),
          body: "Please also update the docs"
        )
        allow(Prompts::BuildForIssue).to receive(:conversation_section_for).and_return(
          Prompts::BuildForIssue.format_conversation_section([ comment ])
        )

        result = activity.execute(project_id: project.id, issue_id: issue.id)

        agent_run = AgentRun.find(result[:agent_run_id])
        expect(agent_run.custom_prompt).to include("Conversation Comments")
        expect(agent_run.custom_prompt).to include("Please also update the docs")
      end

      it "appends service environment guidance for configured database containers" do
        project.service_containers << create(:service_container, account: project.account)

        result = activity.execute(project_id: project.id, issue_id: issue.id)

        agent_run = AgentRun.find(result[:agent_run_id])
        expect(agent_run.custom_prompt).to include("Service Environment")
        expect(agent_run.custom_prompt).to include("Run `bin/rails db:prepare`")
        expect(agent_run.custom_prompt).to include("DATABASE_URL")
        expect(agent_run.custom_prompt).not_to include("Environment Constraints")
      end

      it "separates appended sections from a template without a trailing newline" do
        prompt.current_version.update_column(:template, "Work on {{title}}")
        project.service_containers << create(:service_container, account: project.account)

        result = activity.execute(project_id: project.id, issue_id: issue.id)

        agent_run = AgentRun.find(result[:agent_run_id])
        expect(agent_run.custom_prompt).to include("Work on #{issue.title}\n\n# Service Environment")
      end
    end

    context "with scope analysis" do
      it "includes scope_analysis in the result when issue has a body" do
        issue.update!(body: <<~TEXT)
          Redesign the notification system. Create models, controllers, views,
          services, and migrations. Add authentication, authorization, and
          background jobs. Refactor the existing code.
        TEXT

        result = activity.execute(project_id: project.id, issue_id: issue.id)

        expect(result[:scope_analysis]).to be_present
        expect(result[:scope_analysis][:confidence]).to be_a(Float)
        expect(result[:scope_analysis][:should_decompose]).to be(true).or be(false)
        expect(result[:scope_analysis][:sub_components]).to be_an(Array)
      end

      it "returns nil scope_analysis when no issue is present" do
        result = activity.execute(
          project_id: project.id,
          issue_id: nil,
          custom_prompt: "Do something"
        )

        expect(result[:scope_analysis]).to be_nil
      end

      it "returns nil scope_analysis when issue body is blank" do
        issue.update!(body: "")

        result = activity.execute(project_id: project.id, issue_id: issue.id)

        expect(result[:scope_analysis]).to be_nil
      end
    end

    context "with agent_run_id (resuming queued run)" do
      it "refreshes a queued run without changing status" do
        queued_run = create(:agent_run, :queued, project: project, issue: issue)

        result = activity.execute(agent_run_id: queued_run.id, project_id: project.id)

        expect(result[:agent_run_id]).to eq(queued_run.id)
        expect(queued_run.reload.status).to eq("queued")
      end

      it "updates issue paid_state to in_progress" do
        queued_run = create(:agent_run, :queued, project: project, issue: issue)

        activity.execute(agent_run_id: queued_run.id, project_id: project.id)

        expect(issue.reload.paid_state).to eq("in_progress")
      end

      it "does not change status for claimed queued runs" do
        claimed_run = create(:agent_run, :queued, project: project, issue: issue, temporal_workflow_id: "wf-123")

        result = activity.execute(agent_run_id: claimed_run.id, project_id: project.id)

        expect(result[:agent_run_id]).to eq(claimed_run.id)
        expect(claimed_run.reload.status).to eq("queued")
      end

      it "refreshes automatic claimed queued runs to the current primary provider before starting" do
        claude_provider = project.created_by.providers.find_by!(provider_key: "claude")
        codex_provider = create(:provider, user: project.created_by, provider_key: "codex")
        claimed_run = create(
          :agent_run,
          :queued,
          project: project,
          issue: issue,
          temporal_workflow_id: "wf-123",
          trigger_type: "automatic",
          provider: claude_provider,
          agent_type: "claude_code"
        )
        project.created_by.settings.update!(default_agent_provider: codex_provider.routing_key)

        activity.execute(agent_run_id: claimed_run.id, project_id: project.id)

        claimed_run.reload
        expect(claimed_run.status).to eq("queued")
        expect(claimed_run.provider).to eq(codex_provider)
        expect(claimed_run.agent_type).to eq("codex")
      end

      it "refreshes automatic queued runs to the current primary provider before starting" do
        claude_provider = project.created_by.providers.find_by!(provider_key: "claude")
        codex_provider = create(:provider, user: project.created_by, provider_key: "codex")
        queued_run = create(
          :agent_run,
          :queued,
          project: project,
          issue: issue,
          trigger_type: "automatic",
          provider: claude_provider,
          agent_type: "claude_code"
        )
        project.created_by.settings.update!(default_agent_provider: codex_provider.routing_key)

        activity.execute(agent_run_id: queued_run.id, project_id: project.id)

        queued_run.reload
        expect(queued_run.status).to eq("queued")
        expect(queued_run.provider).to eq(codex_provider)
        expect(queued_run.agent_type).to eq("codex")
      end

      it "preserves manual queued runs when resuming" do
        claude_provider = project.created_by.providers.find_by!(provider_key: "claude")
        codex_provider = create(:provider, user: project.created_by, provider_key: "codex")
        queued_run = create(
          :agent_run,
          :queued,
          project: project,
          issue: issue,
          trigger_type: "manual",
          provider: claude_provider,
          agent_type: "claude_code"
        )
        project.created_by.settings.update!(default_agent_provider: codex_provider.routing_key)

        activity.execute(agent_run_id: queued_run.id, project_id: project.id)

        queued_run.reload
        expect(queued_run.status).to eq("queued")
        expect(queued_run.provider).to eq(claude_provider)
        expect(queued_run.agent_type).to eq("claude_code")
      end
    end
  end

  def expect_requested_provider_decision(decision:, provider_id:, provider_key:, agent_type:)
    expect(decision).to be_present
    expect(decision.context).to include(
      "decision_status" => "applied",
      "issue_id" => issue.id
    )
    expect(decision.inputs.dig("requested_selection", "provider_id")).to eq(provider_id)
    expect(decision.inputs.dig("repository", "full_name")).to eq(project.full_name)
    expect(decision.outputs).to include(
      "outcome" => "selected",
      "selection" => include(
        "provider_id" => provider_id,
        "provider_key" => provider_key,
        "agent_type" => agent_type,
        "candidates" => include(
          include("rank" => 1, "selected" => true, "provider_id" => provider_id, "provider_key" => provider_key)
        )
      )
    )
  end

  def expect_failed_provider_decision(decision:, provider_id:)
    expect(decision.agent_run_id).to be_nil
    expect(decision.decision_type).to eq("select_agent")
    expect(decision.context["decision_status"]).to eq("failed")
    expect(decision.inputs.dig("requested_selection", "provider_id")).to eq(provider_id)
    expect(decision.outputs["error"]).to include(
      "class" => "Temporalio::Error::ApplicationError",
      "message" => include("provider_id=#{provider_id}")
    )
  end
end
