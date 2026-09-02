# frozen_string_literal: true

require "rails_helper"
require "ostruct"

RSpec.describe Activities::CreateAgentRunActivity do
  let(:activity) { described_class.new }
  let(:project) { create(:project) }
  let(:issue) { create(:issue, project: project) }
  let(:claude_runner) { project.created_by.runners.find_by!(runner_key: "claude") }
  let(:codex_runner) { create(:runner, user: project.created_by, runner_key: "codex") }

  def create_service_environment_prompt(slug, template)
    Prompt.find_by(slug: slug)&.destroy!
    create(:prompt, :global, slug: slug).tap do |prompt|
      prompt.create_version!(template: template)
    end
  end

  def create_service_environment_prompts
    [
      create_service_environment_prompt(
        Prompts::ServiceContainerSections::RUBY_DB_SETUP_SLUG,
        "Custom Ruby DB setup guidance."
      ),
      create_service_environment_prompt(
        Prompts::ServiceContainerSections::AVAILABLE_SERVICES_INTRO_SLUG,
        "Custom services intro."
      ),
      create_service_environment_prompt(
        Prompts::ServiceContainerSections::SCHEMA_WORKFLOW_RUBY_SLUG,
        "Custom schema workflow."
      )
    ]
  end

  def expected_service_environment_prompt_blocks(prompts)
    prompts.map { |prompt|
      {
        "slug" => prompt.slug,
        "prompt_id" => prompt.id,
        "prompt_version_id" => prompt.current_version.id,
        "version_number" => prompt.current_version.version,
        "source" => "versioned"
      }
    }
  end

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
      expect(result[:runner_attempt_count]).to eq(1)
      agent_run = AgentRun.find(result[:agent_run_id])
      expect(agent_run.project).to eq(project)
      expect(agent_run.issue).to eq(issue)
      expect(agent_run.status).to eq("queued")
      expect(agent_run.agent_type).to eq("claude_code")
      expect(agent_run.configuration_bundle).to be_present
    end

    it "reuses the AgentRun when retried with the same workflow_id" do
      base_input = { project_id: project.id, issue_id: issue.id, workflow_id: "wf-idempotent-123" }

      first = activity.execute(**base_input)
      second = activity.execute(**base_input)

      expect(second[:agent_run_id]).to eq(first[:agent_run_id])
      expect(AgentRun.where(temporal_workflow_id: "wf-idempotent-123").count).to eq(1)
    end

    it "returns the project max_execution_seconds in the result" do
      project.update!(max_execution_seconds: 900)
      result = activity.execute(project_id: project.id, issue_id: issue.id)

      expect(result[:max_execution_seconds]).to eq(900)
    end

    it "returns default max_execution_seconds when not customized" do
      result = activity.execute(project_id: project.id, issue_id: issue.id)

      expect(result[:max_execution_seconds]).to eq(7200)
    end

    it "returns the user override for max_execution_seconds when set" do
      project.update!(max_execution_seconds: 900)
      project.created_by.settings.update!(max_execution_seconds: 1800)

      result = activity.execute(project_id: project.id, issue_id: issue.id)

      expect(result[:max_execution_seconds]).to eq(1800)
    end

    it "accepts a custom agent_type" do
      result = activity.execute(project_id: project.id, issue_id: issue.id, agent_type: "gemini")

      agent_run = AgentRun.find(result[:agent_run_id])
      expect(agent_run.agent_type).to eq("gemini")
      expect(result[:runner_attempt_count]).to eq(1)
    end

    it "accepts copilot as a container-executable agent_type" do
      result = activity.execute(project_id: project.id, issue_id: issue.id, agent_type: "copilot")

      agent_run = AgentRun.find(result[:agent_run_id])
      expect(agent_run.agent_type).to eq("copilot")
      expect(result[:runner_attempt_count]).to eq(1)
    end

    it "derives agent_type from runner_id when only a runner is supplied" do
      runner = create(:runner, user: project.created_by, runner_key: "cursor")

      result = activity.execute(project_id: project.id, issue_id: issue.id, runner_id: runner.id)

      agent_run = AgentRun.find(result[:agent_run_id])
      expect(agent_run.runner).to eq(runner)
      expect(agent_run.agent_type).to eq("cursor")
    end

    it "records the runner selection decision with requested and ranked alternatives" do
      runner = create(:runner, user: project.created_by, runner_key: "cursor")

      result = activity.execute(project_id: project.id, issue_id: issue.id, runner_id: runner.id)

      agent_run = AgentRun.find(result[:agent_run_id])
      decision = agent_run.orchestration_decisions.where(decision_type: "select_agent").find_by(actor: "requested_provider")

      expect_requested_provider_decision(
        decision: decision,
        runner_id: runner.id,
        runner_key: "cursor",
        agent_type: "cursor"
      )
    end

    it "falls back to the runnable default when a requested runner_id is not container executable" do
      runner = create(:runner, user: project.created_by, runner_key: "copilot")
      allow(RunnerSupport).to receive(:container_executable_runner_key?).and_call_original
      allow(RunnerSupport).to receive(:container_executable_runner_key?).with("copilot").and_return(false)

      result = activity.execute(project_id: project.id, issue_id: issue.id, runner_id: runner.id)

      agent_run = AgentRun.find(result[:agent_run_id])
      expect(agent_run.runner).to eq(project.created_by.runners.find_by!(runner_key: "claude"))
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

    it "persists named plan docs for lid_planning runs" do
      result = activity.execute(
        project_id: project.id,
        goal: "lid_planning",
        plan_docs: [ { name: "docs/rdrs/RDR-051-lid-aware-agent-runs.md" } ]
      )

      agent_run = AgentRun.find(result[:agent_run_id])
      expect(agent_run.custom_prompt).to include("docs/rdrs/RDR-051-lid-aware-agent-runs.md")
      expect(agent_run.external_metadata["plan_docs"]).to eq(
        [ { "name" => "docs/rdrs/RDR-051-lid-aware-agent-runs.md" } ]
      )
    end

    it "filters out malformed plan docs without crashing" do
      result = activity.execute(
        project_id: project.id,
        goal: "lid_planning",
        plan_docs: [ { "name" => "docs/rdrs/RDR-051.md" }, { "path" => "no-name" } ]
      )

      agent_run = AgentRun.find(result[:agent_run_id])
      expect(agent_run.external_metadata["plan_docs"]).to eq(
        [ { "name" => "docs/rdrs/RDR-051.md" } ]
      )
    end

    it "builds the lid_planning prompt on resume when plan_docs are in external_metadata" do
      queued_run = create(:agent_run, :queued, :automatic,
        project: project,
        goal: "lid_planning",
        custom_prompt: nil,
        external_metadata: { "plan_docs" => [ { "name" => "docs/hld.md" } ] })

      activity.execute(agent_run_id: queued_run.id)

      queued_run.reload
      expect(queued_run.custom_prompt).to include("docs/hld.md")
    end

    it "persists the focus when provided" do
      result = activity.execute(
        project_id: project.id,
        issue_id: issue.id,
        focus: "ci_fix"
      )

      agent_run = AgentRun.find(result[:agent_run_id])
      expect(agent_run.focus).to eq("ci_fix")
      expect(result[:focus]).to eq("ci_fix")
    end

    it "uses the configured primary runner when agent type is omitted" do
      codex_runner = create(:runner, user: project.created_by, runner_key: "codex")
      project.created_by.settings.update!(default_agent_runner: codex_runner.routing_key)

      result = activity.execute(project_id: project.id, issue_id: issue.id)

      agent_run = AgentRun.find(result[:agent_run_id])
      expect(agent_run.runner).to eq(codex_runner)
      expect(agent_run.agent_type).to eq("codex")
    end

    it "fails fast when a selected runner is disabled for agent runs" do
      codex_runner = create(:runner, user: project.created_by, runner_key: "codex")
      codex_runner.update!(enabled_for_agent_runs: false)

      expect {
        activity.execute(project_id: project.id, issue_id: issue.id, runner_id: codex_runner.id)
      }.to raise_error(Temporalio::Error::ApplicationError) { |error|
        expect(error.type).to eq("NoRunnableProvider")
        expect(error.non_retryable).to be(true)
      }
    end

    it "fails fast when an explicit runner_id no longer resolves" do
      missing_provider_id = create(:runner, user: project.created_by, runner_key: "cursor").id
      Runner.find(missing_provider_id).destroy!

      expect {
        activity.execute(
          project_id: project.id,
          issue_id: issue.id,
          runner_id: missing_provider_id,
          agent_type: "claude_code"
        )
      }.to raise_error(Temporalio::Error::ApplicationError) { |error|
        expect(error.type).to eq("NoRunnableProvider")
        expect(error.non_retryable).to be(true)
      }

      decision = project.orchestration_decisions.order(:id).last

      expect_failed_provider_decision(decision: decision, runner_id: missing_provider_id)
    end

    it "uses the goal-specific runner for fresh review runs" do
      codex_runner = create(:runner, user: project.created_by, runner_key: "codex")
      project.created_by.settings.update!(default_agent_runners_by_goal: { "review" => codex_runner.routing_key })

      result = activity.execute(
        project_id: project.id,
        issue_id: issue.id,
        goal: "review",
        source_pull_request_number: 42
      )

      agent_run = AgentRun.find(result[:agent_run_id])
      expect(agent_run.runner).to eq(codex_runner)
      expect(agent_run.agent_type).to eq("codex")
    end

    it "refreshes automatic runs to the goal-specific default runner on resume" do
      codex_runner = create(:runner, user: project.created_by, runner_key: "codex")
      queued_run = create(
        :agent_run,
        :queued,
        project: project,
        issue: issue,
        source_pull_request_number: 42,
        trigger_type: "automatic",
        goal: "review"
      )
      project.created_by.settings.update!(default_agent_runners_by_goal: { "review" => codex_runner.routing_key })

      result = activity.execute(agent_run_id: queued_run.id)

      agent_run = AgentRun.find(result[:agent_run_id])
      expect(agent_run.runner).to eq(codex_runner)
      expect(agent_run.agent_type).to eq("codex")
      expect(agent_run.status).to eq("queued")
      expect(agent_run.configuration_bundle.definition).to include(
        "runner_id" => codex_runner.id,
        "agent_type" => "codex"
      )
    end

    it "preserves the existing configuration bundle on resume when provider selection is unchanged" do
      existing_bundle = create_runtime_bundle(existing_create_pr_bundle_definition)
      queued_run = create(:agent_run,
        :queued,
        project: project,
        issue: issue,
        runner: claude_runner,
        agent_type: "claude_code",
        configuration_bundle: existing_bundle)

      activity.execute(agent_run_id: queued_run.id)

      expect(queued_run.reload.configuration_bundle).to eq(existing_bundle)
    end

    it "records schedule_to_start latency per account when resuming a queued run" do
      queued_run = create(
        :agent_run,
        :queued,
        project: project,
        issue: issue,
        created_at: 2.hours.ago,
        queue_entered_at: 90.seconds.ago
      )

      freeze_time do
        activity.execute(agent_run_id: queued_run.id)
      end

      metric_log = queued_run.reload.agent_run_logs.metric.order(:id).last
      expect_schedule_to_start_metric(metric_log, account_id: project.account_id, project_id: project.id, min_seconds: 89.0)
    end

    it "recomputes the configuration bundle on resume when automatic runner selection changes" do
      existing_bundle = create(:configuration_bundle,
        account: project.account,
        definition: existing_review_bundle_definition)
      queued_run = create_review_run_with_bundle(existing_bundle)
      project.created_by.settings.update!(default_agent_runners_by_goal: { "review" => codex_runner.routing_key })

      activity.execute(agent_run_id: queued_run.id)

      queued_run.reload
      expect(queued_run.runner).to eq(codex_runner)
      expect(queued_run.agent_type).to eq("codex")
      expect(queued_run.configuration_bundle).not_to eq(existing_bundle)
      expect(queued_run.configuration_bundle.definition).to include(
        "runner_id" => codex_runner.id,
        "agent_type" => "codex"
      )
    end

    it "recomputes the configuration bundle on resume when model selection metadata becomes available" do
      existing_bundle = create(:configuration_bundle,
        account: project.account,
        definition: existing_create_pr_bundle_definition)
      queued_run = create(:agent_run,
        :queued,
        project: project,
        issue: issue,
        runner: claude_runner,
        agent_type: "claude_code",
        configuration_bundle: existing_bundle)
      llm_model = create(:llm_model, provider: "openai", model_id: "gpt-5.4")

      stub_model_selection(llm_model: llm_model)

      activity.execute(agent_run_id: queued_run.id)

      queued_run.reload
      expect(queued_run.configuration_bundle).not_to eq(existing_bundle)
      expect_model_selection_bundle(queued_run.configuration_bundle)
    end

    def existing_review_bundle_definition
      {
        "schema_version" => 2,
        "goal" => "review",
        "agent_type" => "claude_code",
        "runner_id" => claude_runner.id,
        "ordered_runner_set" => [ claude_runner.runner_key ]
      }
    end

    def existing_create_pr_bundle_definition
      {
        "schema_version" => 2,
        "goal" => "create_pr",
        "agent_type" => "claude_code",
        "runner_id" => claude_runner.id,
        "ordered_runner_set" => [ claude_runner.runner_key ],
        "marketplace_entries" => [],
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
        runner: claude_runner,
        agent_type: "claude_code",
        configuration_bundle: bundle)
    end

    def create_runtime_bundle(definition)
      assigner = ConfigurationBundles::AssignToRun.new(agent_run: build(:agent_run, project: project, issue: issue))
      fingerprint = assigner.send(:bundle_fingerprint, definition)

      create(:configuration_bundle,
        account: project.account,
        definition: definition,
        fingerprint: fingerprint,
        context: {
          "identity" => {
            "fingerprint" => fingerprint,
            "fingerprint_algorithm" => "sha256",
            "schema_version" => 2
          }
        },
        name: "Runtime Bundle #{fingerprint.first(12)}",
        status: "active",
        strategy: "runtime_snapshot")
    end

    def stub_model_selection(llm_model:)
      allow(Models::Select).to receive(:call) do |agent_run:|
        create(:model_selection,
          agent_run: agent_run,
          llm_model: llm_model,
          selector_type: "override",
          tier: "high")
      end
    end

    def expect_model_selection_bundle(bundle)
      expect(bundle.definition).to include(
        "model_selection" => hash_including(
          "selector_type" => "override",
          "tier" => "high"
        )
      )
    end

    def expect_schedule_to_start_metric(metric_log, account_id:, project_id:, min_seconds:)
      expect(metric_log.metadata).to include(
        "type" => "schedule_to_start_latency",
        "account_id" => account_id
      )

      payload = JSON.parse(metric_log.content)
      expect(payload).to include(
        "metric_name" => "schedule_to_start_latency",
        "account_id" => account_id,
        "project_id" => project_id,
        "queue" => Paid.agent_task_queue
      )
      expect(payload.fetch("seconds")).to be >= min_seconds
    end

    it "fails fast when a resumed queued run refreshes to a runner now disabled for agent runs" do
      codex_runner = create(:runner, user: project.created_by, runner_key: "codex")
      queued_run = create(:agent_run, :queued, :automatic,
        project: project, issue: issue, runner: claude_runner, agent_type: "claude_code")
      codex_runner.update!(enabled_for_agent_runs: false)
      allow(activity).to receive(:resolve_runner_selection).and_return([ codex_runner.id, "codex" ])

      expect {
        activity.execute(agent_run_id: queued_run.id)
      }.to raise_error(Temporalio::Error::ApplicationError) { |error|
        expect(error.type).to eq("NoRunnableProvider")
        expect(error.non_retryable).to be(true)
      }

      expect(queued_run.reload.runner).to eq(claude_runner)
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

    it "returns deduplicated runner_attempt_count when fallback is enabled" do
      allow(RunnerSupport).to receive(:container_executable_runner_keys).and_return(%w[claude cursor codex])
      project.created_by.runners.find_or_create_by!(runner_key: "cursor")
      project.created_by.runners.find_or_create_by!(runner_key: "codex")
      project.created_by.settings.update!(fallback_enabled: true, fallback_runners: %w[claude cursor codex])

      result = activity.execute(project_id: project.id, issue_id: issue.id, agent_type: "claude_code")

      expect(result[:runner_attempt_count]).to eq(3)
    end

    it "counts configured fallback-only providers even when not explicitly ordered yet" do
      allow(RunnerSupport).to receive(:container_executable_runner_keys).and_return(%w[claude cursor codex])
      project.created_by.runners.find_or_create_by!(
        runner_key: "cursor",
        enabled_for_agent_runs: false,
        enabled_for_fallback: true
      )
      project.created_by.settings.update!(fallback_enabled: true, fallback_runners: [])

      result = activity.execute(project_id: project.id, issue_id: issue.id, agent_type: "claude_code")

      expect(result[:runner_attempt_count]).to eq(2)
    end

    it "returns one attempt for an explicitly selected runner when fallback is disabled" do
      runner = create(:runner, user: project.created_by, runner_key: "cursor")
      project.created_by.settings.update!(fallback_enabled: false, fallback_runners: [ runner.routing_key ])

      result = activity.execute(project_id: project.id, issue_id: issue.id, runner_id: runner.id, agent_type: "cursor")

      expect(result[:runner_attempt_count]).to eq(1)
    end

    it "counts fallbacks for an explicitly selected runner only when fallback is enabled" do
      primary_provider = create(:runner, user: project.created_by, runner_key: "cursor")
      fallback_provider = create(:runner, user: project.created_by, runner_key: "codex")
      project.created_by.runners.find_by!(runner_key: "claude").update!(enabled_for_fallback: false)
      project.created_by.settings.update!(fallback_enabled: true, fallback_runners: [ fallback_provider.routing_key ])

      result = activity.execute(project_id: project.id, issue_id: issue.id, runner_id: primary_provider.id, agent_type: "cursor")

      expect(result[:runner_attempt_count]).to eq(2)
    end

    it "includes rate-limit fallback entries in runner_attempt_count" do
      allow(RunnerSupport).to receive(:container_executable_runner_keys).and_return(%w[claude cursor])
      api_key = create(:provider_api_key, user: project.created_by, api_service_type: "anthropic")
      project.created_by.runners.create!(
        runner_key: "claude",
        auth_type: "api_key",
        provider_api_key: api_key,
        fallback_role: "rate_limit_fallback",
        enabled_for_agent_runs: false,
        enabled_for_fallback: true
      )
      project.created_by.runners.find_or_create_by!(runner_key: "cursor")
      project.created_by.settings.update!(fallback_enabled: true, fallback_runners: [ "cursor" ])

      result = activity.execute(project_id: project.id, issue_id: issue.id, agent_type: "claude_code")

      expect(result[:runner_attempt_count]).to eq(3)
    end

    it "warns when the selected runner is already rate limited" do
      logger = instance_spy(Logger, info: nil, warn: nil)
      allow(activity).to receive(:logger).and_return(logger)

      create(
        :provider_state,
        :rate_limited,
        user: project.created_by,
        runner_name: "claude"
      )

      activity.execute(project_id: project.id, issue_id: issue.id)

      expect(logger).to have_received(:warn).with(
        hash_including(
          message: "agent_execution.selected_runner_rate_limited",
          project_id: project.id,
          runner_key: "claude",
          runner_state_name: "claude",
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

    it "pauses the run when execution policy approval is required" do
      create_execution_policy(
        "controls" => { "runner_allowlist" => [ "claude" ] },
        "risk_rules" => [
          { "name" => "bugfix", "conditions" => { "issue_labels_any" => [ "bug" ] }, "score" => 80 }
        ],
        "approval_rules" => [
          {
            "name" => "owner_review",
            "conditions" => { "risk_score_gte" => 80 },
            "workflow" => { "required" => true, "reason" => "Owner approval required", "approvers" => [ "repo_owner" ] }
          }
        ]
      )
      issue.update!(labels: [ "bug" ])

      result = activity.execute(project_id: project.id, issue_id: issue.id)

      agent_run = AgentRun.find(result[:agent_run_id])
      expect(result[:paused]).to be(true)
      expect(agent_run.status).to eq("paused")
      expect(agent_run.error_message).to eq("Policy approval required: Owner approval required")
      expect(agent_run.guardrail_context.dig("policy_controls", "approval", "required")).to be(true)
    end

    # @spec EXECUTION-AUDIT-004
    it "records requested and queued execution audit events" do
      result = activity.execute(project_id: project.id, issue_id: issue.id)

      agent_run = AgentRun.find(result[:agent_run_id])
      events = ExecutionAuditEvent.for_agent_run(agent_run)
        .where(event_name: %w[execution.requested execution.queued])
        .order(:id)

      expect(events.pluck(:event_name)).to eq(%w[execution.requested execution.queued])
      expect(events.map(&:actor_id)).to eq([ "activities.create_agent_run", "activities.create_agent_run" ])
    end

    it "redacts the custom prompt before persistence when prompt redaction is enabled" do
      create_execution_policy(
        "controls" => {
          "prompt_redaction" => {
            "enabled" => true,
            "classify" => true,
            "block_fully_redacted" => false
          }
        }
      )
      custom_prompt = "token=" + "ghp_" + "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmn"

      result = activity.execute(
        project_id: project.id,
        issue_id: issue.id,
        custom_prompt:
      )

      agent_run = AgentRun.find(result[:agent_run_id])
      expect(agent_run.custom_prompt).to include("[REDACTED:")
      expect(agent_run.guardrail_context.dig("policy_controls", "classification")).not_to be_empty
      expect(agent_run.status).to eq("queued")
    end

    def create_execution_policy(rules)
      create(:coordination_policy,
        :active,
        account: project.account,
        project: project,
        policy_type: "execution",
        policy_key: "agent_execution").tap do |policy|
        policy.current_version.update!(rules: rules)
      end
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
      let(:github_client) { instance_double(GithubClient, issue_comments: []) }

      let!(:prompt) do
        p = Prompt.global.find_or_create_by!(slug: "coding.issue_implementation") do |record|
          record.name = "Issue implementation"
          record.category = "coding"
          record.active = true
        end
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

      before do
        project.update!(allowed_github_usernames: [ issue.github_creator_login ])
        allow(GithubClient).to receive(:new).and_return(github_client)
      end

      it "resolves prompt version without materializing a custom prompt for create_pr" do
        result = activity.execute(project_id: project.id, issue_id: issue.id)

        agent_run = AgentRun.find(result[:agent_run_id])
        expect(agent_run.prompt_version).to eq(prompt.current_version)
        expect(agent_run.custom_prompt).to be_nil
      end

      it "renders the selected prompt version at runtime with the correct variables" do
        result = activity.execute(project_id: project.id, issue_id: issue.id)

        agent_run = AgentRun.find(result[:agent_run_id])
        prompt_text = agent_run.prompt_for_issue
        expect(prompt_text).to include(issue.title)
        expect(prompt_text).to include(issue.github_number.to_s)
        expect(prompt_text).to include("Test: bundle exec rspec")
        expect(prompt_text).to include("Lint: bundle exec rubocop")
      end

      # @spec POLYGLOT-TEST-003
      it "renders every language's command for a polyglot project at runtime" do
        project.update!(repo_profile: { "test_languages" => [ "ruby", "elixir" ] })

        result = activity.execute(project_id: project.id, issue_id: issue.id)

        agent_run = AgentRun.find(result[:agent_run_id])
        prompt_text = agent_run.prompt_for_issue
        expect(prompt_text).to include("Test: bundle exec rspec, then mix test")
        expect(prompt_text).to include("Lint: bundle exec rubocop, then mix credo --strict")
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

      it "rejects analyze_issue for an untrusted issue" do
        untrusted_issue = create(:issue, project: project, github_creator_login: "untrusted-user")

        expect {
          activity.execute(project_id: project.id, issue_id: untrusted_issue.id, goal: "analyze_issue")
        }.to raise_error(Temporalio::Error::ApplicationError) { |error|
          expect(error.type).to eq("UntrustedIssue")
          expect(error.non_retryable).to be(true)
        }
      end

      it "rejects enhance_issue for an untrusted issue" do
        untrusted_issue = create(:issue, project: project, github_creator_login: "untrusted-user")

        expect {
          activity.execute(project_id: project.id, issue_id: untrusted_issue.id, goal: "enhance_issue")
        }.to raise_error(Temporalio::Error::ApplicationError) { |error|
          expect(error.type).to eq("UntrustedIssue")
          expect(error.non_retryable).to be(true)
        }
      end

      it "includes trusted issue comments in the assembled runtime prompt" do
        trusted_login = "trusted-dev"
        project.update!(allowed_github_usernames: [ issue.github_creator_login, trusted_login ])
        comment = OpenStruct.new(
          user: OpenStruct.new(login: trusted_login),
          body: "Please also update the docs"
        )
        allow(Prompts::BuildForIssue).to receive(:conversation_section_for).and_call_original
        allow(github_client).to receive(:issue_comments).and_return([ comment ])

        result = activity.execute(project_id: project.id, issue_id: issue.id)

        agent_run = AgentRun.find(result[:agent_run_id])
        prompt_text = agent_run.prompt_for_issue
        expect(agent_run.custom_prompt).to be_nil
        expect(prompt_text).to include("Conversation Comments")
        expect(prompt_text).to include("Please also update the docs")
      end

      it "injects style guides and records exposures for the assembled runtime prompt" do
        guide = create(:style_guide, account: project.account, project: nil, name: "Team Guide", raw_content: "Prefer small methods.")

        result = activity.execute(project_id: project.id, issue_id: issue.id)

        agent_run = AgentRun.find(result[:agent_run_id])
        prompt_text = agent_run.effective_prompt
        exposure = agent_run.style_guide_run_exposures.find_by!(style_guide: guide)
        expect(prompt_text).to include("Team Guide")
        expect(exposure.style_guide_version).to eq(guide.current_version)
      end

      it "assembles service environment guidance for configured database containers" do
        project.service_containers << create(:service_container, account: project.account)

        result = activity.execute(project_id: project.id, issue_id: issue.id)

        agent_run = AgentRun.find(result[:agent_run_id])
        prompt_text = agent_run.prompt_for_issue
        expect(prompt_text).to include("Available Services")
        expect(prompt_text).to include("Database Schema Workflow")
        expect(prompt_text).to include("DATABASE_URL")
        expect(prompt_text).not_to include("Environment Constraints")
      end

      it "records rendered service environment prompt versions in phase metadata" do
        project.service_containers << create(:service_container, account: project.account)
        prompts = create_service_environment_prompts

        result = activity.execute(project_id: project.id, issue_id: issue.id)

        agent_run = AgentRun.find(result[:agent_run_id])
        phase = agent_run.agent_run_phases.find_by!(phase_key: "create_agent_run")

        expect(phase.metadata["service_environment_prompt_blocks"]).to eq(expected_service_environment_prompt_blocks(prompts))
      end

      it "separates assembled sections from a template without a trailing newline" do
        prompt.current_version.update_column(:template, "Work on {{title}}")
        project.service_containers << create(:service_container, account: project.account)

        result = activity.execute(project_id: project.id, issue_id: issue.id)

        agent_run = AgentRun.find(result[:agent_run_id])
        expect(agent_run.prompt_for_issue).to include("Work on #{issue.title}\n\n# Available Services")
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

      it "refreshes automatic claimed queued runs to the current primary runner before starting" do
        claude_runner = project.created_by.runners.find_by!(runner_key: "claude")
        codex_runner = create(:runner, user: project.created_by, runner_key: "codex")
        claimed_run = create(
          :agent_run,
          :queued,
          project: project,
          issue: issue,
          temporal_workflow_id: "wf-123",
          trigger_type: "automatic",
          runner: claude_runner,
          agent_type: "claude_code"
        )
        project.created_by.settings.update!(default_agent_runner: codex_runner.routing_key)

        activity.execute(agent_run_id: claimed_run.id, project_id: project.id)

        claimed_run.reload
        expect(claimed_run.status).to eq("queued")
        expect(claimed_run.runner).to eq(codex_runner)
        expect(claimed_run.agent_type).to eq("codex")
      end

      it "refreshes automatic queued runs to the current primary runner before starting" do
        claude_runner = project.created_by.runners.find_by!(runner_key: "claude")
        codex_runner = create(:runner, user: project.created_by, runner_key: "codex")
        queued_run = create(
          :agent_run,
          :queued,
          project: project,
          issue: issue,
          trigger_type: "automatic",
          runner: claude_runner,
          agent_type: "claude_code"
        )
        project.created_by.settings.update!(default_agent_runner: codex_runner.routing_key)

        activity.execute(agent_run_id: queued_run.id, project_id: project.id)

        queued_run.reload
        expect(queued_run.status).to eq("queued")
        expect(queued_run.runner).to eq(codex_runner)
        expect(queued_run.agent_type).to eq("codex")
      end

      it "preserves manual queued runs when resuming" do
        claude_runner = project.created_by.runners.find_by!(runner_key: "claude")
        codex_runner = create(:runner, user: project.created_by, runner_key: "codex")
        queued_run = create(
          :agent_run,
          :queued,
          project: project,
          issue: issue,
          trigger_type: "manual",
          runner: claude_runner,
          agent_type: "claude_code"
        )
        project.created_by.settings.update!(default_agent_runner: codex_runner.routing_key)

        activity.execute(agent_run_id: queued_run.id, project_id: project.id)

        queued_run.reload
        expect(queued_run.status).to eq("queued")
        expect(queued_run.runner).to eq(claude_runner)
        expect(queued_run.agent_type).to eq("claude_code")
      end
    end
  end

  describe "orchestration strategy selection" do
    def create_issue_execution_strategy(**attrs)
      strategy = create(:strategy, :global, decision_type: "issue_execution", selection_rules: {}, **attrs)
      reviewer = create(:user, account: strategy.account || create(:account))
      version = strategy.create_version!(
        content: { "focus_override" => "ci_fix" },
        provenance: { "source" => "seed" },
        promotion_state: "active",
        created_by: "seed",
        promoted_at: Time.current,
        promoted_by_user: reviewer
      )
      strategy.update!(current_version: version)
      strategy
    end

    it "logs an OrchestrationDecision with fallback status when no strategy matches" do
      result = activity.execute(project_id: project.id, issue_id: issue.id)
      agent_run = AgentRun.find(result[:agent_run_id])

      decision = agent_run.orchestration_decisions.find_by(decision_type: "issue_execution")
      expect(decision).to be_present
      expect(decision.actor).to eq("Activities::CreateAgentRunActivity")
      expect(decision.context["decision_status"]).to eq("noop")
      expect(decision.context["scope"]).to eq("fallback")
      expect(decision.strategy_version).to be_nil
    end

    it "logs an OrchestrationDecision linking the matched strategy version" do
      strategy = create_issue_execution_strategy

      result = activity.execute(project_id: project.id, issue_id: issue.id)
      agent_run = AgentRun.find(result[:agent_run_id])

      decision = agent_run.orchestration_decisions.find_by(decision_type: "issue_execution")
      expect(decision).to be_present
      expect(decision.context["decision_status"]).to eq("applied")
      expect(decision.context["scope"]).to eq("global")
      expect(decision.strategy_version).to eq(strategy.current_version)
      expect(decision.outputs).to eq({ "focus_override" => "ci_fix" })
    end

    it "records inputs capturing the run context" do
      result = activity.execute(project_id: project.id, issue_id: issue.id)
      agent_run = AgentRun.find(result[:agent_run_id])

      decision = agent_run.orchestration_decisions.find_by(decision_type: "issue_execution")
      expect(decision.inputs).to include(
        "goal" => agent_run.goal,
        "agent_type" => agent_run.agent_type,
        "focus" => agent_run.focus
      )
    end

    it "continues run creation even if strategy selection raises" do
      allow(Strategies::Select).to receive(:call).and_raise(RuntimeError, "strategy db error")

      expect { activity.execute(project_id: project.id, issue_id: issue.id) }.not_to raise_error
      expect(AgentRun.where(project: project)).to exist
    end

    context "when resuming a queued run" do
      it "logs an OrchestrationDecision for the resumed run" do
        queued_run = create(:agent_run, :queued, project: project, issue: issue)

        activity.execute(agent_run_id: queued_run.id)

        decision = queued_run.orchestration_decisions.find_by(decision_type: "issue_execution")
        expect(decision).to be_present
        expect(decision.actor).to eq("Activities::CreateAgentRunActivity")
      end
    end
  end

  describe "create_feature needs-input flow" do
    let(:feature_issue) { create(:issue, project: project, title: "[Feature] Add dark mode", body: "Need dark mode") }

    before do
      allow(Prompts::BuildForCreateFeature).to receive(:call).and_return("feature prompt")
      stub_request(:post, %r{api\.github\.com/repos/.*/issues/.*/comments}).to_return(status: 200, body: "{}")
      stub_request(:post, %r{api\.github\.com/repos/.*/issues/.*/labels}).to_return(status: 200, body: "[]")
      allow(Projects::EnsureStandardLabels).to receive(:call_best_effort)
    end

    it "returns paused: true via resume_queued_run when feature brief is sparse" do
      agent_run = create(:agent_run, :queued, :create_feature_goal, project: project, issue: feature_issue)
      agent_run.update!(external_metadata: { "feature_brief" => { "title" => "Add dark mode", "problem" => "Need dark mode" } })

      result = activity.execute(agent_run_id: agent_run.id)

      expect(result[:paused]).to be true
      expect(result[:agent_run_id]).to eq(agent_run.id)
      expect(agent_run.reload.status).to eq("paused")
    end

    it "persists clarifying questions locally so the dashboard avoids a per-issue API round-trip" do
      agent_run = create(:agent_run, :queued, :create_feature_goal, project: project, issue: feature_issue)
      agent_run.update!(external_metadata: { "feature_brief" => { "title" => "Add dark mode", "problem" => "Need dark mode" } })

      activity.execute(agent_run_id: agent_run.id)

      expect(feature_issue.reload.needs_input_questions).to be_an(Array).and include(
        a_string_matching(/desired behavior/),
        a_string_matching(/constraints/),
        a_string_matching(/scope/)
      )
    end

    # @spec GH-LABELS-001
    it "syncs the standard label catalog before applying the needs-input label" do
      agent_run = create(:agent_run, :queued, :create_feature_goal, project: project, issue: feature_issue)
      agent_run.update!(external_metadata: { "feature_brief" => { "title" => "Add dark mode", "problem" => "Need dark mode" } })

      activity.execute(agent_run_id: agent_run.id)

      expect(Projects::EnsureStandardLabels).to have_received(:call_best_effort).with(project: project, logger: anything)
    end

    it "does not pause when feature brief has all required fields" do
      full_brief = {
        "title" => "Add dark mode",
        "problem" => "Need dark mode",
        "desired_behavior" => "Toggle dark mode in settings",
        "constraints" => [ "Must work with SSR" ],
        "scope" => { "in" => "Color palette", "out" => "Syntax highlighting" },
        "done_criteria" => "Visual regression tests pass"
      }
      agent_run = create(:agent_run, :queued, :create_feature_goal, project: project, issue: feature_issue)
      agent_run.update!(external_metadata: { "feature_brief" => full_brief })

      result = activity.execute(agent_run_id: agent_run.id)

      expect(result[:paused]).to be_falsey
    end

    describe "#build_feature_clarifying_questions_comment" do
      it "includes the enhance-issue marker and clarifying questions section" do
        comment = activity.send(:build_feature_clarifying_questions_comment)

        expect(comment).to include("<!-- paid:enhance-issue -->")
        expect(comment).to include("## Clarifying questions")
        expect(comment).to include("desired behavior")
        expect(comment).to include("constraints")
        expect(comment).to include("alternatives")
        expect(comment).to include("scope")
        expect(comment).to include("done")
      end
    end

    describe "#feature_brief_sparse?" do
      it "returns true when brief is nil" do
        agent_run = build(:agent_run, :create_feature_goal, external_metadata: {})
        expect(activity.send(:feature_brief_sparse?, agent_run)).to be true
      end

      it "returns true when brief lacks required fields" do
        agent_run = build(:agent_run, :create_feature_goal,
          external_metadata: { "feature_brief" => { "title" => "Test", "problem" => "Test" } })
        expect(activity.send(:feature_brief_sparse?, agent_run)).to be true
      end

      it "returns false when brief has all required fields" do
        brief = {
          "title" => "Test", "problem" => "Test",
          "desired_behavior" => "X", "constraints" => [ "Y" ],
          "scope" => { "in" => "Z" }, "done_criteria" => "Done"
        }
        agent_run = build(:agent_run, :create_feature_goal, external_metadata: { "feature_brief" => brief })
        expect(activity.send(:feature_brief_sparse?, agent_run)).to be false
      end
    end
  end

  def expect_requested_provider_decision(decision:, runner_id:, runner_key:, agent_type:)
    expect(decision).to be_present
    expect(decision.context).to include(
      "decision_status" => "applied",
      "issue_id" => issue.id
    )
    expect(decision.inputs.dig("requested_selection", "runner_id")).to eq(runner_id)
    expect(decision.inputs.dig("repository", "full_name")).to eq(project.full_name)
    expect(decision.outputs).to include(
      "outcome" => "selected",
      "selection" => include(
        "runner_id" => runner_id,
        "provider_key" => runner_key,
        "agent_type" => agent_type,
        "candidates" => include(
          include("rank" => 1, "selected" => true, "runner_id" => runner_id, "provider_key" => runner_key)
        )
      )
    )
  end

  def expect_failed_provider_decision(decision:, runner_id:)
    expect(decision.agent_run_id).to be_nil
    expect(decision.decision_type).to eq("select_agent")
    expect(decision.context["decision_status"]).to eq("failed")
    expect(decision.inputs.dig("requested_selection", "runner_id")).to eq(runner_id)
    expect(decision.outputs["error"]).to include(
      "class" => "Temporalio::Error::ApplicationError",
      "message" => include("runner_id=#{runner_id}")
    )
  end
end
