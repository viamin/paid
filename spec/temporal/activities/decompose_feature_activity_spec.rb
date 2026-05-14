# frozen_string_literal: true

require "rails_helper"

RSpec.describe Activities::DecomposeFeatureActivity do
  let(:activity) { described_class.new }
  let(:project) { create(:project) }
  let(:issue) { create(:issue, project: project, title: "Add OAuth", body: "Implement OAuth 2.0 login") }

  describe "#with_policy_provenance", :no_db do
    let(:policy_metadata) do
      {
        policy_source: "coordination_policy",
        policy_key: DecompositionService::POLICY_KEY,
        coordination_policy_version: 5
      }
    end

    it "normalizes nested policy_metadata keys while exposing top-level provenance" do
      result = activity.send(
        :with_policy_provenance,
        {
          tasks: [],
          policy_metadata: policy_metadata.deep_stringify_keys
        }
      )

      expect(result[:policy_metadata]).to eq(policy_metadata)
      expect(result).to include(policy_metadata)
    end

    it "normalizes fully string-keyed policy payloads" do
      result = activity.send(
        :with_policy_provenance,
        {
          "tasks" => [],
          "policy_metadata" => policy_metadata.deep_stringify_keys
        }
      )

      expect(result).to include(tasks: [])
      expect(result[:policy_metadata]).to eq(policy_metadata)
      expect(result).to include(policy_metadata)
    end
  end

  describe "#result_policy_metadata", :no_db do
    it "extracts provenance from symbol-keyed policy payloads" do
      decomposition_result = instance_double(
        DecompositionService::Result,
        policy_source: "coordination_policy",
        skip_reason: nil,
        policy_applied: {
          policy_key: DecompositionService::POLICY_KEY,
          coordination_policy_id: 12,
          coordination_policy_version_id: 34,
          coordination_policy_version: 5
        }
      )

      result = activity.send(:result_policy_metadata, decomposition_result)

      expect(result).to eq(
        policy_source: "coordination_policy",
        policy_key: DecompositionService::POLICY_KEY,
        coordination_policy_id: 12,
        coordination_policy_version_id: 34,
        coordination_policy_version: 5
      )
    end
  end

  describe "#application_error_with_policy_provenance", :no_db do
    let(:policy_metadata) do
      {
        policy_source: "coordination_policy",
        policy_key: DecompositionService::POLICY_KEY,
        coordination_policy_version: 5
      }
    end

    it "appends policy provenance to Temporal application error details" do
      error = Temporalio::Error::ApplicationError.new("LLM failed", type: "DecompositionFailed")

      enriched_error = activity.send(
        :application_error_with_policy_provenance,
        error,
        { metadata: policy_metadata }
      )

      expect(enriched_error).not_to be(error)
      expect(enriched_error.details).to include(policy_metadata:)
      expect(enriched_error.type).to eq("DecompositionFailed")
    end

    it "leaves errors untouched when no policy metadata is available" do
      error = Temporalio::Error::ApplicationError.new("LLM failed", type: "DecompositionFailed")

      expect(
        activity.send(:application_error_with_policy_provenance, error, { metadata: {} })
      ).to be(error)
    end
  end

  describe "#execute" do
    let(:logged_decision) { build_stubbed(:decomposition_decision, decision_type: "decomposition_strategy") }
    let(:llm_response) do
      instance_double(
        AgentHarness::Response,
        success?: true,
        output: llm_output,
        error: nil
      )
    end

    let(:llm_output) do
      <<~JSON
        [
          {"title": "Add OAuth migration", "description": "Create oauth_tokens table", "dependencies": [], "parallel_group": 0},
          {"title": "Implement OAuth model", "description": "Create OAuthToken model", "dependencies": [0], "parallel_group": 1},
          {"title": "Add OAuth controller", "description": "Create OAuth callback endpoint", "dependencies": [1], "parallel_group": 2}
        ]
      JSON
    end

    let(:knowledge_context) do
      { issue_title: "Add OAuth", knowledge_snippets: [] }
    end

    before do
      allow(AgentHarness).to receive(:send_message).and_return(llm_response)
      allow(Orchestration::DecompositionDecisions::Log).to receive(:call).and_return(logged_decision)
      allow(Prompt).to receive(:resolve).and_return(nil)
      # Default: preserve CLI transport so existing exact-match expectations
      # pass. Individual specs flip this on to prove text-mode routing.
      allow(Llm::TextMode).to receive(:options).and_return({})
    end

    def execute_with_workflow_context(workflow_name:, workflow_id:)
      activity.execute(
        project_id: project.id,
        issue_id: issue.id,
        knowledge_context: knowledge_context,
        workflow_name: workflow_name,
        workflow_id: workflow_id
      )
    end

    def expect_llm_strategy_decision_logged(workflow_name:, workflow_id:, outcome:, prompt_source:)
      expect(Orchestration::DecompositionDecisions::Log).to have_received(:call).with(
        hash_including(
          workflow_name: workflow_name,
          workflow_id: workflow_id,
          decision_type: "decomposition_strategy",
          outcome: outcome,
          input_context: hash_including(
            coordination_policy_present: false
          ),
          metadata: hash_including(
            workflow_step: "decompose_feature",
            prompt_source: prompt_source,
            activity_boundaries: [ "Activities::DecomposeFeatureActivity" ]
          )
        )
      )
    end

    def expect_policy_decomposition_logged(workflow_name:, workflow_id:, outcome:, coordination_policy_present:)
      expect(Orchestration::DecompositionDecisions::Log).to have_received(:call).with(
        hash_including(
          workflow_name: workflow_name,
          workflow_id: workflow_id,
          outcome: outcome,
          input_context: hash_including(
            coordination_policy_present: coordination_policy_present
          ),
          metadata: hash_including(
            prompt_source: "policy_service",
            policy_attempted: true
          )
        )
      )
    end

    def expect_oauth_tasks(tasks)
      expect(tasks.size).to eq(3)
      expect(tasks[0][:title]).to eq("Add OAuth migration")
      expect(tasks[0][:dependencies]).to eq([])
      expect(tasks[0][:parallel_group]).to eq(0)
      expect(tasks[1][:dependencies]).to eq([ 0 ])
      expect(tasks[2][:dependencies]).to eq([ 1 ])
    end

    def expect_policy_skip_result(result)
      expect(result[:prompt_source]).to eq(described_class::POLICY_PROMPT_SOURCE)
      expect(result[:tasks]).to eq([])
      expect(result[:skip_reason]).to eq("decomposition_disabled_by_policy")
      expect(result[:policy_metadata]).to include(policy_source: "feature_orchestration")
      expect(AgentHarness).not_to have_received(:send_message)
      expect(Orchestration::DecompositionDecisions::Log).to have_received(:call).with(
        hash_including(
          outcome: "policy_skipped",
          input_context: hash_including(
            coordination_policy_present: true
          ),
          plan_data: hash_including(tasks: [])
        )
      )
    end

    it "returns parsed tasks from LLM output" do
      result = execute_with_workflow_context(
        workflow_name: "Workflows::PlanningWorkflow",
        workflow_id: "planning-wf-1"
      )

      expect_oauth_tasks(result[:tasks])
      expect(result[:prompt_source]).to eq("fallback_prompt")
      expect(result[:policy_metadata]).to eq({})
      expect_llm_strategy_decision_logged(
        workflow_name: "Workflows::PlanningWorkflow",
        workflow_id: "planning-wf-1",
        outcome: "llm_generated_plan",
        prompt_source: "fallback_prompt"
      )
      expect(Orchestration::DecompositionDecisions::Log).to have_received(:call).with(
        hash_including(
          plan_data: hash_including(tasks: array_including(hash_including(title: "Add OAuth migration")))
        )
      )
    end

    context "when policy-based decomposition applies" do
      let(:issue) do
        create(
          :issue,
          project: project,
          title: "Add notifications",
          body: "Add database tables, service layer, API endpoints, and views for notifications."
        )
      end

      it "uses DecompositionService instead of the LLM path" do
        result = execute_with_workflow_context(
          workflow_name: "Workflows::FeatureOrchestrationWorkflow",
          workflow_id: "orchestration-wf-1"
        )

        expect(result[:prompt_source]).to eq(described_class::POLICY_PROMPT_SOURCE)
        expect(result[:tasks]).to all(include(:dependencies, :parallel_group, :scope))
        expect(result[:policy_metadata]).to include(
          policy_source: "feature_orchestration",
          policy_key: DecompositionService::POLICY_KEY
        )
        expect(AgentHarness).not_to have_received(:send_message)
        expect_policy_decomposition_logged(
          workflow_name: "Workflows::FeatureOrchestrationWorkflow",
          workflow_id: "orchestration-wf-1",
          outcome: "policy_decomposed",
          coordination_policy_present: false
        )
      end
    end

    context "when a strategy exists without decomposition config and issue is below threshold" do
      let(:project) { create(:project, account: account) }
      let(:account) { create(:account) }

      before do
        create(:orchestration_strategy, :feature_orchestration, :with_account,
          account: account)
      end

      it "falls back to LLM decomposition" do
        result = activity.execute(
          project_id: project.id,
          issue_id: issue.id,
          knowledge_context: knowledge_context
        )

        expect(result[:prompt_source]).to eq("fallback_prompt")
        expect(AgentHarness).to have_received(:send_message)
      end
    end

    context "when a custom policy disables decomposition" do
      let(:project) { create(:project, account: account) }
      let(:account) { create(:account) }
      let(:issue) do
        create(
          :issue,
          project: project,
          title: "Add notifications",
          body: "Add database tables, service layer, API endpoints, and views for notifications."
        )
      end

      before do
        create(:orchestration_strategy, :feature_orchestration, :with_account,
          account: account,
          configuration: OrchestrationStrategies::Defaults.feature_orchestration.merge(
            "decomposition" => { "enabled" => false }
          ))
      end

      it "returns the policy-based skip result without calling the LLM" do
        result = activity.execute(
          project_id: project.id,
          issue_id: issue.id,
          knowledge_context: knowledge_context,
          workflow_name: "Workflows::FeatureOrchestrationWorkflow",
          workflow_id: "orchestration-wf-2"
        )

        expect_policy_skip_result(result)
      end
    end

    context "when an active coordination policy drives decomposition" do
      let(:project) { create(:project, account: account) }
      let(:account) { create(:account) }
      let(:issue) do
        create(
          :issue,
          project: project,
          title: "Add notifications",
          body: "Add database tables, service layer, API endpoints, and views for notifications."
        )
      end

      before do
        create(:coordination_policy, :active,
          account: account,
          project: nil,
          policy_type: DecompositionService::POLICY_TYPE,
          policy_key: DecompositionService::POLICY_KEY).tap do |policy|
          policy.current_version.update!(
            rules: { "enabled" => true, "min_components_to_decompose" => 2 },
            parameters: { "max_tasks" => 2 }
          )
        end
      end

      it "marks coordination_policy_present and skips the LLM fallback" do
        result = activity.execute(
          project_id: project.id,
          issue_id: issue.id,
          knowledge_context: knowledge_context,
          workflow_name: "Workflows::FeatureOrchestrationWorkflow",
          workflow_id: "orchestration-wf-3"
        )

        expect(result[:prompt_source]).to eq(described_class::POLICY_PROMPT_SOURCE)
        expect(result[:tasks].size).to eq(2)
        expect(result[:policy_metadata]).to include(
          policy_source: "coordination_policy",
          policy_key: DecompositionService::POLICY_KEY
        )
        expect(AgentHarness).not_to have_received(:send_message)
        expect_policy_decomposition_logged(
          workflow_name: "Workflows::FeatureOrchestrationWorkflow",
          workflow_id: "orchestration-wf-3",
          outcome: "policy_decomposed",
          coordination_policy_present: true
        )
      end
    end

    context "when strategy resolution raises and issue is below threshold" do
      before do
        allow(OrchestrationStrategies::Resolve).to receive(:call)
          .and_raise(StandardError, "connection timeout")
      end

      it "falls back to LLM decomposition instead of returning an empty plan" do
        result = activity.execute(
          project_id: project.id,
          issue_id: issue.id,
          knowledge_context: knowledge_context,
          workflow_name: "Workflows::PlanningWorkflow",
          workflow_id: "planning-wf-2"
        )

        expect(result[:prompt_source]).to eq("fallback_prompt")
        expect(result[:tasks]).not_to be_empty
        expect(AgentHarness).to have_received(:send_message)
      end
    end

    context "when scope analysis raises" do
      let(:logger) { instance_spy(Logger) }

      before do
        allow(activity).to receive(:logger).and_return(logger)
        allow(ScopeAnalysis::Analyze).to receive(:call)
          .and_raise(StandardError, "scope failure")
      end

      it "logs and falls back to LLM decomposition" do
        result = activity.execute(
          project_id: project.id,
          issue_id: issue.id,
          knowledge_context: knowledge_context
        )

        expect(result[:prompt_source]).to eq("fallback_prompt")
        expect(result[:tasks]).not_to be_empty
        expect(AgentHarness).to have_received(:send_message)
        expect(logger).to have_received(:warn).with(
          message: "planning.policy_decomposition_failed",
          error_class: "StandardError",
          error: "scope failure"
        )
      end
    end

    context "when policy decomposition raises" do
      let(:logger) { instance_spy(Logger) }
      let(:scope_result) do
        double(
          should_decompose?: true,
          confidence: 0.9,
          sub_components: [ "api" ]
        )
      end

      before do
        allow(activity).to receive(:logger).and_return(logger)
        allow(ScopeAnalysis::Analyze).to receive(:call).and_return(scope_result)
        allow(DecompositionService).to receive(:call)
          .and_raise(StandardError, "decomposition failure")
      end

      it "logs and falls back to LLM decomposition" do
        result = execute_with_workflow_context(
          workflow_name: "Workflows::PlanningWorkflow",
          workflow_id: "planning-wf-3"
        )

        expect(result[:prompt_source]).to eq("fallback_prompt")
        expect(result[:tasks]).not_to be_empty
        expect(AgentHarness).to have_received(:send_message)
        expect(logger).to have_received(:warn).with(
          message: "planning.policy_decomposition_failed",
          error_class: "StandardError",
          error: "decomposition failure"
        )
        expect_llm_strategy_decision_logged(
          workflow_name: "Workflows::PlanningWorkflow",
          workflow_id: "planning-wf-3",
          outcome: "llm_fallback_after_policy_failure",
          prompt_source: "fallback_prompt"
        )
      end
    end

    it "calls AgentHarness with the correct provider and model" do
      activity.execute(
        project_id: project.id,
        issue_id: issue.id,
        knowledge_context: knowledge_context
      )

      expect(AgentHarness).to have_received(:send_message).with(
        a_string_including("Add OAuth"),
        provider: :claude,
        model: described_class::DEFAULT_MODEL,
        timeout: described_class::TIMEOUT,
        tools: :none
      )
    end

    it "routes through agent-harness text mode when an API key is configured" do
      allow(Llm::TextMode).to receive(:options).and_return(mode: :text)

      activity.execute(
        project_id: project.id,
        issue_id: issue.id,
        knowledge_context: knowledge_context
      )

      expect(AgentHarness).to have_received(:send_message)
        .with(anything, hash_including(mode: :text))
    end

    it "includes knowledge context in the prompt when available" do
      context_with_knowledge = knowledge_context.merge(
        knowledge_snippets: [ { title: "Auth docs", content: "OAuth pattern info" } ]
      )

      activity.execute(
        project_id: project.id,
        issue_id: issue.id,
        knowledge_context: context_with_knowledge
      )

      expect(AgentHarness).to have_received(:send_message).with(
        a_string_including("Auth docs"),
        provider: :claude,
        model: described_class::DEFAULT_MODEL,
        timeout: described_class::TIMEOUT,
        tools: :none
      )
    end

    it "returns active_prompt when a seeded prompt version is available" do
      prompt_version = instance_double(PromptVersion, render: "[]")
      prompt = instance_double(Prompt, current_version: prompt_version)
      allow(Prompt).to receive(:resolve).and_return(prompt)

      result = activity.execute(
        project_id: project.id,
        issue_id: issue.id,
        knowledge_context: knowledge_context
      )

      expect(result[:prompt_source]).to eq("active_prompt")
    end

    context "when LLM returns a single task" do
      let(:llm_output) do
        '[{"title": "Simple fix", "description": "Just update the config", "dependencies": [], "parallel_group": 0}]'
      end

      it "returns a single task" do
        result = activity.execute(
          project_id: project.id,
          issue_id: issue.id,
          knowledge_context: knowledge_context
        )

        expect(result[:tasks].size).to eq(1)
        expect(result[:tasks][0][:title]).to eq("Simple fix")
      end
    end

    context "when LLM returns markdown-fenced JSON" do
      let(:llm_output) do
        <<~OUTPUT
          ```json
          [{"title": "Task 1", "description": "Do thing", "dependencies": [], "parallel_group": 0}]
          ```
        OUTPUT
      end

      it "strips the markdown fence and parses correctly" do
        result = activity.execute(
          project_id: project.id,
          issue_id: issue.id,
          knowledge_context: knowledge_context
        )

        expect(result[:tasks].size).to eq(1)
        expect(result[:tasks][0][:title]).to eq("Task 1")
      end
    end

    context "when LLM call fails" do
      let(:llm_response) do
        instance_double(AgentHarness::Response, success?: false, output: nil, error: "Rate limited")
      end

      it "raises an ApplicationError" do
        expect {
          activity.execute(
            project_id: project.id,
            issue_id: issue.id,
            knowledge_context: knowledge_context,
            workflow_name: "Workflows::PlanningWorkflow",
            workflow_id: "planning-wf-4"
          )
        }.to raise_error(Temporalio::Error::ApplicationError, /LLM decomposition failed/)
        expect(Orchestration::DecompositionDecisions::Log).to have_received(:call).with(
          hash_including(
            decision_key: "planning-wf-4:decomposition_strategy:failure",
            outcome: "llm_decomposition_failed",
            error_details: hash_including(error_message: "LLM decomposition failed: Rate limited")
          )
        )
      end
    end

    context "when LLM returns invalid JSON" do
      let(:llm_output) { "This is not valid JSON at all" }

      it "raises an ApplicationError" do
        expect {
          activity.execute(
            project_id: project.id,
            issue_id: issue.id,
            knowledge_context: knowledge_context,
            workflow_name: "Workflows::PlanningWorkflow",
            workflow_id: "planning-wf-5"
          )
        }.to raise_error(Temporalio::Error::ApplicationError, /Failed to parse/)
        expect(Orchestration::DecompositionDecisions::Log).to have_received(:call).with(
          hash_including(
            outcome: "llm_decomposition_failed",
            error_details: hash_including(error_message: a_string_including("Failed to parse"))
          )
        )
      end
    end

    context "when LLM returns non-array JSON" do
      let(:llm_output) { '{"title": "Not an array"}' }

      it "raises an ApplicationError" do
        expect {
          activity.execute(
            project_id: project.id,
            issue_id: issue.id,
            knowledge_context: knowledge_context
          )
        }.to raise_error(Temporalio::Error::ApplicationError, /non-array/)
      end
    end

    context "when LLM returns array with non-Hash elements" do
      before do
        allow(llm_response).to receive(:output).and_return('["not a hash", null, 42]')
      end

      it "raises a non-retryable ApplicationError" do
        expect {
          activity.execute(
            project_id: project.id,
            issue_id: issue.id,
            knowledge_context: knowledge_context
          )
        }.to raise_error(Temporalio::Error::ApplicationError, /non-Hash element/)
      end
    end

    it "truncates tasks to MAX_TASKS" do
      many_tasks = (0..25).map do |i|
        { title: "Task #{i}", description: "Desc #{i}", dependencies: [], parallel_group: i }
      end
      allow(llm_response).to receive(:output).and_return(many_tasks.to_json)

      result = activity.execute(
        project_id: project.id,
        issue_id: issue.id,
        knowledge_context: knowledge_context
      )

      expect(result[:tasks].size).to eq(described_class::MAX_TASKS)
    end
  end
end
