# frozen_string_literal: true

require "rails_helper"

# @spec MODEL-SELECTION-001, MODEL-SELECTION-004
RSpec.describe Models::Select do
  describe ".call" do
    let(:project) { create(:project) }
    let(:agent_run) { create(:agent_run, project: project) }

    before do
      # Default: meta-agent returns nil so rules-based fallback is used
      allow(Models::MetaAgentSelector).to receive(:call).and_return(nil)
    end

    context "with project model override (required_model_id)" do
      let!(:llm_model) { create(:llm_model, model_id: "claude-sonnet-4-6", tier: "high") }
      let(:decision_log) { agent_run.agent_run_logs.where(log_type: "system").order(:id).last }
      let(:orchestration_decision) { agent_run.orchestration_decisions.order(:id).last }

      before do
        project.update!(model_preferences: { "required_model_id" => "claude-sonnet-4-6" })
      end

      it "selects the overridden model" do
        selection = described_class.call(agent_run: agent_run)

        expect(selection).to be_a(ModelSelection)
        expect(selection.llm_model).to eq(llm_model)
        expect(selection.selector_type).to eq("override")
      end

      it "records the tier from the selected model" do
        selection = described_class.call(agent_run: agent_run)

        expect(selection.tier).to eq("high")
      end

      it "persists a ModelSelection record" do
        expect { described_class.call(agent_run: agent_run) }
          .to change(ModelSelection, :count).by(1)
      end

      it "logs the persisted selection outcome" do
        create(:cost_budget, :hard_stop, :per_run, project: project, limit_cents: 1_200, current_usage_cents: 300)

        selection = described_class.call(agent_run: agent_run)

        expect(decision_log).to be_present
        expect(decision_log.content).to include("Agent selection succeeded")
        expect(decision_log.metadata).to include("type" => "model_selection_decision", "outcome" => "selected")
        expect(decision_log.metadata.dig("selection", "model_selection_id")).to eq(selection.id)
        expect(decision_log.metadata.dig("selection", "agent_type")).to eq(agent_run.agent_type)
        expect(decision_log.metadata.dig("selection", "provider_key")).to eq("claude")
        expect(decision_log.metadata.dig("selection", "runner_key")).to eq("claude")
        expect(decision_log.metadata.dig("selection", "model_id")).to eq("claude-sonnet-4-6")
        expect(decision_log.metadata.dig("selection", "model_provider")).to eq(llm_model.provider)
      end

      it "records an orchestration decision with selection context" do
        selection = described_class.call(agent_run: agent_run)

        expect(orchestration_decision).to be_present
        expect(orchestration_decision.decision_type).to eq("select_agent")
        expect(orchestration_decision.actor).to eq("override")
        expect(orchestration_decision.context).to include(
          "decision_status" => "applied",
          "issue_id" => agent_run.issue_id,
          "data_classification" => project.data_classification
        )
        expect(orchestration_decision.outputs).to include(
          "outcome" => "selected",
          "selection" => include(
            "model_selection_id" => selection.id,
            "model_id" => "claude-sonnet-4-6"
          )
        )
      end

      it "logs ranked candidates for the selection" do
        described_class.call(agent_run: agent_run)

        expect(decision_log.metadata.dig("selection", "candidates")).to contain_exactly(
          include(
            "rank" => 1,
            "selected" => true,
            "model_id" => "claude-sonnet-4-6",
            "provider" => llm_model.provider,
            "tier" => "high"
          )
        )
      end

      it "logs task and repository selection inputs" do
        create(:cost_budget, :hard_stop, :per_run, project: project, limit_cents: 1_200, current_usage_cents: 300)

        described_class.call(agent_run: agent_run)

        expect(decision_log.metadata.dig("inputs", "task")).to include(
          "goal" => agent_run.goal,
          "trigger_type" => agent_run.trigger_type,
          "issue_id" => agent_run.issue_id
        )
        expect(decision_log.metadata.dig("inputs", "repository")).to include(
          "project_id" => project.id,
          "full_name" => project.full_name
        )
      end

      it "logs policy constraints and budget signals" do
        create(:cost_budget, :hard_stop, :per_run, project: project, limit_cents: 1_200, current_usage_cents: 300)

        described_class.call(agent_run: agent_run)

        expect(decision_log.metadata.dig("inputs", "policy_constraints")).to include(
          "required_model_id" => "claude-sonnet-4-6"
        )
        expect(decision_log.metadata.dig("inputs", "budget_signals", "active_budgets")).to contain_exactly(
          include(
            "budget_type" => "per_run",
            "enforcement_mode" => "hard_stop",
            "limit_cents" => 1200,
            "remaining_cents" => 900,
            "hard_stop" => true
          )
        )
      end

      it "does not call meta-agent or rules-based selector" do
        allow(Models::RulesBasedSelector).to receive(:call)

        described_class.call(agent_run: agent_run)

        expect(Models::MetaAgentSelector).not_to have_received(:call)
        expect(Models::RulesBasedSelector).not_to have_received(:call)
      end
    end

    context "with project preferred models" do
      let!(:preferred_model) { create(:llm_model, model_id: "gpt-4o", capability_score: 8.5, tier: "mid") }

      before do
        create(:llm_model, model_id: "claude-sonnet-4-6", capability_score: 9.0, tier: "high")
        project.update!(model_preferences: { "preferred_model_ids" => [ "gpt-4o" ] })
      end

      it "selects the preferred model" do
        selection = described_class.call(agent_run: agent_run)

        expect(selection.llm_model).to eq(preferred_model)
        expect(selection.selector_type).to eq("override")
        expect(selection.reasoning).to include("preferred")
      end

      it "does not call meta-agent selector" do
        described_class.call(agent_run: agent_run)

        expect(Models::MetaAgentSelector).not_to have_received(:call)
      end
    end

    context "with multiple preferred models respects ordering" do
      let!(:higher_capability) { create(:llm_model, model_id: "claude-sonnet-4-6", capability_score: 9.0, tier: "high") }
      let!(:first_choice) { create(:llm_model, model_id: "gpt-4o", capability_score: 7.0, tier: "mid") }

      before do
        project.update!(model_preferences: { "preferred_model_ids" => [ "gpt-4o", "claude-sonnet-4-6" ] })
      end

      it "selects the first active model in preference order, not by capability" do
        selection = described_class.call(agent_run: agent_run)

        expect(selection.llm_model).to eq(first_choice)
        expect(selection.llm_model).not_to eq(higher_capability)
      end
    end

    context "when preferred model is inactive" do
      before do
        create(:llm_model, model_id: "gpt-4o", active: false)
        create(:llm_model, model_id: "claude-sonnet-4-6")
        project.update!(model_preferences: { "preferred_model_ids" => [ "gpt-4o" ] })
      end

      it "falls through to meta-agent/rules selection" do
        selection = described_class.call(agent_run: agent_run)

        expect(selection.selector_type).to eq("rules")
      end
    end

    context "with tenant model preference" do
      let!(:tenant_model) { create(:llm_model, model_id: "claude-tenant-default", tier: "high") }

      before do
        create(:tenant_setting, account: project.account,
          provider_preferences: { "model_preferences" => { "claude" => tenant_model.model_id } })
      end

      it "selects the tenant default model for the run runner" do
        selection = described_class.call(agent_run: agent_run)

        expect(selection.llm_model).to eq(tenant_model)
        expect(selection.selector_type).to eq("override")
        expect(selection.reasoning).to include("Tenant preferred model")
      end
    end

    context "with active quality-triggered escalation" do
      let!(:preferred_model) { create(:llm_model, model_id: "preferred-mid", tier: "mid", capability_score: 7.0) }
      let!(:high_model) { create(:llm_model, model_id: "quality-high", tier: "high", capability_score: 10.0) }

      before do
        project.update!(model_preferences: {
          "preferred_model_ids" => [ preferred_model.model_id ],
          "quality_triggered_escalation" => {
            "status" => "active",
            "trigger" => "quality_drop",
            "from_tier" => "mid",
            "to_tier" => "high"
          }
        })
      end

      it "selects the escalated tier and tracks the quality reason" do
        selection = described_class.call(agent_run: agent_run)

        expect(selection.llm_model).to eq(high_model)
        expect(selection.selector_type).to eq("quality_escalation")
        expect(selection.tier).to eq("high")
        expect(selection.reasoning).to include("Quality-triggered")
      end
    end

    context "with prompt evolution requested for quality recovery" do
      let!(:preferred_model) { create(:llm_model, model_id: "preferred-mid", tier: "mid", capability_score: 7.0) }
      let!(:high_model) { create(:llm_model, model_id: "quality-high", tier: "high", capability_score: 10.0) }

      before do
        project.update!(model_preferences: {
          "preferred_model_ids" => [ preferred_model.model_id ],
          "quality_triggered_escalation" => {
            "status" => "prompt_evolution_requested",
            "trigger" => "quality_drop",
            "from_tier" => "mid",
            "to_tier" => "high"
          }
        })
      end

      it "keeps selecting the escalated tier while prompt evolution is pending" do
        selection = described_class.call(agent_run: agent_run)

        expect(selection.llm_model).to eq(high_model)
        expect(selection.selector_type).to eq("quality_escalation")
        expect(selection.tier).to eq("high")
      end
    end

    context "with meta-agent selection" do
      let!(:llm_model) { create(:llm_model, model_id: "claude-sonnet-4-6", capability_score: 9.0) }

      before do
        allow(Models::MetaAgentSelector).to receive(:call).and_return({
          model: llm_model,
          selector_type: "meta_agent",
          tier: "high",
          reasoning: "Complex task needs high capability",
          candidates: [ { model_id: "claude-sonnet-4-6", score: 9.0 } ],
          complexity_score: 7.5
        })
      end

      it "uses meta-agent result" do
        selection = described_class.call(agent_run: agent_run)

        expect(selection).to be_a(ModelSelection)
        expect(selection.selector_type).to eq("meta_agent")
        expect(selection.reasoning).to eq("Complex task needs high capability")
        expect(selection.complexity_score).to eq(7.5)
      end

      it "persists the meta-agent tier" do
        selection = described_class.call(agent_run: agent_run)

        expect(selection.tier).to eq("high")
      end

      it "does not mark an escalation without a quality recovery reason" do
        selection = described_class.call(agent_run: agent_run)

        expect(selection.escalated_from_tier).to be_nil
        expect(selection.escalated_reason).to be_nil
      end
    end

    context "when meta-agent fails and falls back to rules" do
      before { create(:llm_model) }

      it "selects a model via rules" do
        selection = described_class.call(agent_run: agent_run)

        expect(selection).to be_a(ModelSelection)
        expect(selection.selector_type).to eq("rules")
      end

      it "records selection duration" do
        selection = described_class.call(agent_run: agent_run)

        expect(selection.selection_duration_ms).to be_a(Integer)
        expect(selection.selection_duration_ms).to be >= 0
      end
    end

    context "when no models are available" do
      it "returns nil" do
        expect(described_class.call(agent_run: agent_run)).to be_nil
      end

      it "logs the no-selection outcome with inputs" do
        described_class.call(agent_run: agent_run)

        log = agent_run.agent_run_logs.where(log_type: "system").order(:id).last

        expect(log).to be_present
        expect(log.content).to include("no eligible models")
        expect(log.metadata).to include("type" => "model_selection_decision", "outcome" => "no_selection")
        expect(log.metadata["selection"]).to be_nil
        expect(log.metadata.dig("inputs", "repository", "full_name")).to eq(project.full_name)
      end

      it "records a noop orchestration decision" do
        described_class.call(agent_run: agent_run)

        decision = agent_run.orchestration_decisions.order(:id).last

        expect(decision.decision_type).to eq("select_agent")
        expect(decision.actor).to eq("model_selection")
        expect(decision.context["decision_status"]).to eq("noop")
        expect(decision.outputs["outcome"]).to eq("no_selection")
      end
    end

    context "when the run uses Codex subscription auth" do
      let(:codex_provider) { create(:provider, user: project.created_by, provider_key: "codex", auth_type: "subscription") }
      let(:agent_run) { create(:agent_run, project: project, provider: codex_provider, agent_type: "codex") }

      before do
        create(:llm_model, :openai, model_id: "gpt-4o", tier: "mid")
        create(:llm_model, :openai, model_id: "gpt-4o-mini", tier: "low")
      end

      it "returns nil instead of persisting an incompatible selected model" do
        expect(described_class.call(agent_run: agent_run)).to be_nil
        expect(agent_run.model_selection).to be_nil
      end

      it "records the no-selection outcome" do
        described_class.call(agent_run: agent_run)

        log = agent_run.agent_run_logs.where(log_type: "system").order(:id).last

        expect(log.metadata).to include("type" => "model_selection_decision", "outcome" => "no_selection")
      end
    end

    context "when override model does not exist" do
      before do
        create(:llm_model)
        project.update!(model_preferences: { "required_model_id" => "nonexistent-model" })
      end

      it "falls back to rules-based selection" do
        selection = described_class.call(agent_run: agent_run)

        expect(selection.selector_type).to eq("rules")
      end
    end

    context "when a fixed-model Pi run is forced to an incompatible override model" do
      let!(:minimax_model) { create(:llm_model, model_id: "MiniMax-M2.7", provider: "minimax", tier: "mid", capability_score: 8.0) }
      let!(:claude_model) { create(:llm_model, model_id: "claude-sonnet-4-6", provider: "anthropic", tier: "mid", capability_score: 9.0) }
      let(:minimax_key) { create(:provider_api_key, user: project.created_by, api_service_type: "minimax") }
      let(:pi_runner) do
        create(
          :runner,
          user: project.created_by,
          runner_key: "pi",
          auth_type: "api_key",
          provider_api_key: minimax_key,
          config: { "pi" => { "api_provider" => "minimax", "model" => minimax_model.model_id } }
        )
      end

      before do
        agent_run.update!(runner: pi_runner)
        project.update!(model_preferences: { "required_model_id" => claude_model.model_id })
      end

      it "returns no selection instead of persisting an incompatible model" do
        expect(described_class.call(agent_run: agent_run)).to be_nil
        expect(agent_run.model_selection).to be_nil
      end

      it "records the no-selection outcome" do
        described_class.call(agent_run: agent_run)

        log = agent_run.agent_run_logs.where(log_type: "system").order(:id).last

        expect(log.metadata).to include("type" => "model_selection_decision", "outcome" => "no_selection")
        expect(log.metadata.dig("selection", "model_id")).to eq(claude_model.model_id)
        expect(log.metadata.dig("selection", "model_provider")).to eq(claude_model.provider)
        expect(log.metadata.dig("selection", "selector_type")).to eq("override")
      end
    end

    context "when an openrouter_free run is forced to a non-free override model" do
      let!(:free_model) { create(:llm_model, model_id: "deepseek/deepseek-v4-flash:free", provider: "deepseek", tier: "mid", pricing_tier: "free", capability_score: 8.0) }
      let!(:paid_model) { create(:llm_model, model_id: "claude-sonnet-4-6", provider: "anthropic", tier: "mid", pricing_tier: "paid", capability_score: 9.0) }
      let(:openrouter_key) { create(:provider_api_key, user: project.created_by, api_service_type: "openrouter") }
      let(:openrouter_free_runner) do
        create(
          :runner,
          user: project.created_by,
          runner_key: "openrouter_free",
          auth_type: "api_key",
          provider_api_key: openrouter_key,
          tier_model_ids: LlmModel::TIERS.index_with { free_model.model_id }
        )
      end

      before { agent_run.update!(runner: openrouter_free_runner) }

      it "returns no selection instead of persisting a paid model" do
        project.update!(model_preferences: { "required_model_id" => paid_model.model_id })

        expect(described_class.call(agent_run: agent_run)).to be_nil
        expect(agent_run.model_selection).to be_nil
      end

      it "persists a free override model" do
        project.update!(model_preferences: { "required_model_id" => free_model.model_id })

        selection = described_class.call(agent_run: agent_run)

        expect(selection).to be_present
        expect(selection.llm_model).to eq(free_model)
      end
    end

    context "when quality escalation fires for a provider-constrained Pi run" do
      let!(:anthropic_high) { create(:llm_model, model_id: "claude-sonnet-4-6", provider: "anthropic", tier: "high", capability_score: 10.0) }
      let(:minimax_key) { create(:provider_api_key, user: project.created_by, api_service_type: "minimax") }
      let(:pi_runner) do
        create(
          :runner,
          user: project.created_by,
          runner_key: "pi",
          auth_type: "api_key",
          provider_api_key: minimax_key,
          config: { "pi" => { "api_provider" => "minimax", "model" => "MiniMax-M2.7" } }
        )
      end

      before do
        agent_run.update!(runner: pi_runner)
        project.update!(model_preferences: {
          "quality_triggered_escalation" => {
            "status" => "active",
            "trigger" => "quality_drop",
            "from_tier" => "mid",
            "to_tier" => "high"
          }
        })
      end

      it "selects the runner's compatible MiniMax model instead of the top global model" do
        selection = described_class.call(agent_run: agent_run)

        expect(selection).to be_a(ModelSelection)
        expect(selection.selector_type).to eq("quality_escalation")
        expect(selection.llm_model.provider).to eq("minimax")
      end

      it "never selects an incompatible provider model during escalation" do
        selection = described_class.call(agent_run: agent_run)

        expect(selection.llm_model).not_to eq(anthropic_high)
      end
    end

    context "when a non-Pi runner has an override model from another provider" do
      let!(:gpt_model) { create(:llm_model, model_id: "gpt-4o", provider: "openai", tier: "mid", capability_score: 8.5) }

      before do
        project.update!(model_preferences: { "required_model_id" => gpt_model.model_id })
      end

      it "still persists the explicit override selection" do
        selection = described_class.call(agent_run: agent_run)

        expect(selection).to be_a(ModelSelection)
        expect(selection.llm_model).to eq(gpt_model)
        expect(selection.selector_type).to eq("override")
      end
    end

    context "when a confidential project selects a risky free model" do
      let!(:free_model) do
        create(
          :llm_model,
          model_id: "free-risky-model",
          tier: "mid",
          pricing_tier: "free",
          data_training_risk: "possible"
        )
      end

      before do
        project.update!(data_classification: "confidential", model_preferences: { "required_model_id" => free_model.model_id })
      end

      it "persists the selection and records the guardrail warning decision" do
        expect { described_class.call(agent_run: agent_run) }
          .to change(ModelSelection, :count).by(1)
          .and change(OrchestrationDecision, :count).by(2)

        warning_decision = agent_run.orchestration_decisions.order(:id).first
        selection_decision = agent_run.orchestration_decisions.order(:id).last

        expect(warning_decision.decision_type).to eq("check_data_classification")
        expect(warning_decision.context).to include(
          "decision_status" => "applied",
          "data_classification" => "confidential"
        )
        expect(selection_decision.context).to include(
          "decision_status" => "applied",
          "data_classification" => "confidential"
        )
        expect(agent_run.model_selection.llm_model).to eq(free_model)
      end
    end

    context "when model is an openrouter_sync free model" do
      let!(:free_model) do
        create(
          :llm_model,
          model_id: "openrouter-free-model",
          tier: "mid",
          pricing_tier: "free",
          data_training_risk: "possible",
          catalog_source: "openrouter_sync"
        )
      end

      before do
        project.update!(data_classification: "restricted", model_preferences: { "required_model_id" => free_model.model_id })
      end

      it "records provider_data_collection without warning" do
        described_class.call(agent_run: agent_run)

        warning_decision = agent_run.orchestration_decisions.order(:id).first
        selection_decision = agent_run.orchestration_decisions.order(:id).last

        expect(warning_decision.context).to include(
          "decision_status" => "noop",
          "data_classification" => "restricted",
          "provider_data_collection" => "deny"
        )
        expect(selection_decision.context).to include(
          "data_classification" => "restricted",
          "provider_data_collection" => "deny"
        )
      end
    end

    context "when required_model_id bypasses tier logic (regression)" do
      let!(:low_tier_model) { create(:llm_model, model_id: "cheap-model", tier: "low", capability_score: 3.0) }

      before do
        # Even with max_tier set, required_model_id must always win
        project.update!(model_preferences: {
          "required_model_id" => "cheap-model",
          "max_tier" => "high"
        })
      end

      it "selects the required model regardless of tier settings" do
        selection = described_class.call(agent_run: agent_run)

        expect(selection.llm_model).to eq(low_tier_model)
        expect(selection.selector_type).to eq("override")
        expect(selection.tier).to eq("low")
      end

      it "does not invoke tier-based selectors" do
        allow(Models::RulesBasedSelector).to receive(:call)

        described_class.call(agent_run: agent_run)

        expect(Models::MetaAgentSelector).not_to have_received(:call)
        expect(Models::RulesBasedSelector).not_to have_received(:call)
      end
    end

    context "when quality recovery escalation is active" do
      before do
        create(:llm_model, model_id: "mid-model", tier: "mid", capability_score: 7.0)
        create(:llm_model, model_id: "low-model", tier: "low", capability_score: 5.0)
        # Use a high escalation floor so the low-complexity run gets escalated
        project.update!(model_preferences: { "quality_recovery_min_tier" => "high" })
        create(:llm_model, model_id: "high-model", tier: "high", capability_score: 9.0)
        # Make the issue short so complexity stays low -> base tier = "low"
        agent_run.issue.update!(body: "x")
      end

      it "records escalation on the ModelSelection" do
        selection = described_class.call(agent_run: agent_run)

        expect(selection.escalated_from_tier).to be_present
        expect(selection.escalated_reason).to eq("quality_recovery_project")
      end

      it "sets the final tier to the escalated tier" do
        selection = described_class.call(agent_run: agent_run)

        expect(selection.tier).to eq("high")
      end
    end

    context "when per-goal escalation is active" do
      before do
        create(:llm_model, model_id: "high-model", tier: "high", capability_score: 9.0)
        create(:llm_model, model_id: "low-model", tier: "low", capability_score: 5.0)
        project.update!(model_preferences: { "goal_min_tiers" => { agent_run.goal => "high" } })
        agent_run.issue.update!(body: "x")
      end

      it "records goal-level escalation reason" do
        selection = described_class.call(agent_run: agent_run)

        expect(selection.escalated_from_tier).to be_present
        expect(selection.escalated_reason).to eq("quality_recovery_goal")
      end
    end

    context "when no escalation is needed (above threshold)" do
      before do
        create(:llm_model, model_id: "low-model", tier: "low", capability_score: 5.0)
      end

      it "does not record escalation" do
        selection = described_class.call(agent_run: agent_run)

        expect(selection.escalated_from_tier).to be_nil
        expect(selection.escalated_reason).to be_nil
      end
    end

    context "when project override still wins over escalation" do
      let!(:low_tier_model) { create(:llm_model, model_id: "cheap-model", tier: "low", capability_score: 3.0) }

      before do
        project.update!(model_preferences: {
          "required_model_id" => "cheap-model",
          "quality_recovery_min_tier" => "high"
        })
      end

      it "selects the required model without escalation marking" do
        selection = described_class.call(agent_run: agent_run)

        expect(selection.llm_model).to eq(low_tier_model)
        expect(selection.selector_type).to eq("override")
        expect(selection.escalated_from_tier).to be_nil
      end
    end

    context "with max_tier project preference" do
      before do
        create(:llm_model, model_id: "powerful-model", tier: "high", capability_score: 9.5)
        create(:llm_model, model_id: "mid-model", tier: "mid", capability_score: 7.0)
        project.update!(model_preferences: { "max_tier" => "mid" })
      end

      it "caps tier selection to the max_tier" do
        selection = described_class.call(agent_run: agent_run)

        expect(selection).to be_a(ModelSelection)
        expect(selection.tier).to be_in(%w[low mid])
      end
    end

    context "when selection raises" do
      before do
        allow(Models::MetaAgentSelector).to receive(:call).and_raise(StandardError, "selector blew up")
      end

      it "logs the failure before re-raising" do
        expect {
          described_class.call(agent_run: agent_run)
        }.to raise_error(StandardError, "selector blew up")

        log = agent_run.agent_run_logs.where(log_type: "system").order(:id).last

        expect(log).to be_present
        expect(log.content).to include("Agent selection failed")
        expect(log.metadata).to include("type" => "model_selection_decision", "outcome" => "failed")
        expect(log.metadata.dig("error", "class")).to eq("StandardError")
        expect(log.metadata.dig("error", "message")).to eq("selector blew up")
      end

      it "records a failed orchestration decision before re-raising" do
        expect {
          described_class.call(agent_run: agent_run)
        }.to raise_error(StandardError, "selector blew up")

        decision = agent_run.orchestration_decisions.order(:id).last

        expect(decision.decision_type).to eq("select_agent")
        expect(decision.actor).to eq("model_selection")
        expect(decision.context["decision_status"]).to eq("failed")
        expect(decision.outputs["error"]).to include(
          "class" => "StandardError",
          "message" => "selector blew up"
        )
      end
    end

    context "when the legacy system log write fails" do
      before do
        create(:llm_model, model_id: "claude-sonnet-4-6", tier: "high")
        project.update!(model_preferences: { "required_model_id" => "claude-sonnet-4-6" })
        allow(agent_run.agent_run_logs).to receive(:create!).and_raise(ActiveRecord::ActiveRecordError, "log write failed")
      end

      it "still records the orchestration decision" do
        selection = described_class.call(agent_run: agent_run)

        expect(selection).to be_present
        decision = agent_run.orchestration_decisions.order(:id).last

        expect(decision).to be_present
        expect(decision.decision_type).to eq("select_agent")
        expect(decision.context["decision_status"]).to eq("applied")
        expect(decision.outputs).to include(
          "outcome" => "selected",
          "selection" => include("model_id" => "claude-sonnet-4-6")
        )
      end
    end

    context "with an LLM provider blocklist" do
      let!(:anthropic_model) { create(:llm_model, model_id: "anthropic-mid", provider: "anthropic", tier: "mid", capability_score: 8.0) }
      let!(:openai_model) { create(:llm_model, :openai, model_id: "gpt-4o", tier: "mid", capability_score: 9.0) }

      before do
        # Force every complexity into the "mid" tier so both candidates are in
        # the same selection bucket (openai ranks higher by capability).
        project.update!(model_preferences: {
          "complexity_thresholds" => { "low_max" => 0, "mid_max" => 10 },
          "llm_providers" => { "blocklist" => [ "openai" ] }
        })
      end

      it "excludes blocklisted providers from automatic selection" do
        selection = described_class.call(agent_run: agent_run)

        expect(selection).to be_a(ModelSelection)
        expect(selection.llm_model).to eq(anthropic_model)
        expect(selection.llm_model.provider).to eq("anthropic")
      end

      it "blocks a required model from a blocklisted provider with a clear reason" do
        project.update!(model_preferences: {
          "complexity_thresholds" => { "low_max" => 0, "mid_max" => 10 },
          "required_model_id" => openai_model.model_id,
          "llm_providers" => { "blocklist" => [ "openai" ] }
        })

        expect(described_class.call(agent_run: agent_run)).to be_nil
        expect(agent_run.model_selection).to be_nil

        log = agent_run.agent_run_logs.where(log_type: "system").order(:id).last
        expect(log.metadata).to include("outcome" => "no_selection")
        expect(log.content).to include("not permitted")
        expect(log.content).to include("openai")
        expect(log.metadata["reason"]).to include("blocklist")
        expect(log.metadata["reason"]).to include("openai")
      end

      it "persists the decision reason on the orchestration decision" do
        project.update!(model_preferences: {
          "required_model_id" => openai_model.model_id,
          "llm_providers" => { "blocklist" => [ "openai" ] }
        })

        described_class.call(agent_run: agent_run)

        decision = agent_run.orchestration_decisions.order(:id).last
        expect(decision.outputs["reason"]).to include("not permitted")
        expect(decision.outputs["reason"]).to include("openai")
      end
    end

    context "with an LLM provider allowlist" do
      let!(:anthropic_model) { create(:llm_model, model_id: "anthropic-mid", provider: "anthropic", tier: "mid", capability_score: 8.0) }
      let!(:openai_model) { create(:llm_model, :openai, model_id: "gpt-4o", tier: "mid", capability_score: 9.0) }

      before do
        project.update!(model_preferences: {
          "complexity_thresholds" => { "low_max" => 0, "mid_max" => 10 },
          "llm_providers" => { "allowlist" => [ "anthropic" ] }
        })
      end

      it "restricts automatic selection to allowlisted providers" do
        selection = described_class.call(agent_run: agent_run)

        expect(selection).to be_a(ModelSelection)
        expect(selection.llm_model).to eq(anthropic_model)
        expect(selection.llm_model.provider).to eq("anthropic")
      end

      it "selects a required model from an allowlisted provider" do
        project.update!(model_preferences: {
          "required_model_id" => anthropic_model.model_id,
          "llm_providers" => { "allowlist" => [ "anthropic" ] }
        })

        selection = described_class.call(agent_run: agent_run)

        expect(selection).to be_a(ModelSelection)
        expect(selection.llm_model).to eq(anthropic_model)
      end

      it "blocks a required model from a non-allowlisted provider with a clear reason" do
        project.update!(model_preferences: {
          "required_model_id" => openai_model.model_id,
          "llm_providers" => { "allowlist" => [ "anthropic" ] }
        })

        expect(described_class.call(agent_run: agent_run)).to be_nil

        log = agent_run.agent_run_logs.where(log_type: "system").order(:id).last
        expect(log.content).to include("not permitted")
        expect(log.content).to include("openai")
        expect(log.metadata["reason"]).to include("allowlist")
      end
    end

    context "when preferred models span blocked and allowed providers" do
      let!(:anthropic_model) { create(:llm_model, model_id: "anthropic-pref", provider: "anthropic", tier: "mid") }
      let!(:openai_model) { create(:llm_model, :openai, model_id: "gpt-pref", tier: "mid") }

      it "skips blocked providers and selects the next allowed preferred model" do
        project.update!(model_preferences: {
          "preferred_model_ids" => [ openai_model.model_id, anthropic_model.model_id ],
          "llm_providers" => { "blocklist" => [ "openai" ] }
        })

        selection = described_class.call(agent_run: agent_run)

        expect(selection.llm_model).to eq(anthropic_model)
        expect(selection.selector_type).to eq("override")
      end
    end

    context "with RDR-040 runner compatibility checks for override paths" do
      # Use the cursor runner (anthropic provider) so an openai override
      # model triggers a :provider_mismatch incompatibility. Cursor is the
      # default factory runner_key so it won't collide with the
      # subscription-uniqueness validation. The account/project need unique
      # slugs/owner-repo pairs because the test database is shared.
      let(:account) do
        create(:account, slug: "rdr040-sel-#{SecureRandom.hex(4)}")
      end
      let(:user) { create(:user, account: account, email: "rdr040-sel-#{SecureRandom.hex(4)}@example.com") }
      let(:github_token) { create(:github_token, account: account, created_by: user) }
      let(:project) { create(:project, account: account, created_by: user, github_token: github_token) }

      let(:cursor_runner) do
        create(:runner, user: project.created_by, runner_key: "cursor", auth_type: "subscription")
      end
      let(:cursor_agent_run) do
        run = create(:agent_run, project: project)
        run.update!(runner: cursor_runner)
        run
      end

      context "when the project required model is incompatible with the bound runner" do
        before do
          # openai model — incompatible with the cursor runner (anthropic).
          create(:llm_model, :openai, model_id: "gpt-4o", provider: "openai", tier: "high")
          project.update!(model_preferences: { "required_model_id" => "gpt-4o" })
        end

        it "returns no selection instead of persisting the incompatible override" do
          expect(described_class.call(agent_run: cursor_agent_run)).to be_nil
          expect(cursor_agent_run.model_selection).to be_nil
        end

        it "records the no-selection outcome with the rejected model surfaced" do
          described_class.call(agent_run: cursor_agent_run)

          log = cursor_agent_run.agent_run_logs.where(log_type: "system").order(:id).last

          expect(log.metadata).to include("outcome" => "no_selection")
          # The selection metadata should still show which model was
          # rejected so an admin can see why no model was selected.
          expect(log.metadata.dig("selection", "model_id")).to eq("gpt-4o")
        end
      end

      context "when the project required model is compatible with the bound runner" do
        before do
          create(:llm_model, model_id: "claude-sonnet-4-6", provider: "anthropic", tier: "high")
          project.update!(model_preferences: { "required_model_id" => "claude-sonnet-4-6" })
        end

        it "selects the override model" do
          selection = described_class.call(agent_run: cursor_agent_run)

          expect(selection).to be_a(ModelSelection)
          expect(selection.llm_model.model_id).to eq("claude-sonnet-4-6")
        end
      end

      context "when a preferred model is incompatible with the bound runner" do
        before do
          # openai model — incompatible with cursor runner (anthropic).
          create(:llm_model, :openai, model_id: "gpt-4o", tier: "high")
          project.update!(model_preferences: { "preferred_model_ids" => [ "gpt-4o" ] })
        end

        it "skips the incompatible preferred model and falls through" do
          selection = described_class.call(agent_run: cursor_agent_run)

          # No override selected because the only preferred model is incompatible.
          if selection
            expect(selection.llm_model.model_id).not_to eq("gpt-4o")
          end
        end
      end

      context "when the tenant-preferred model is incompatible with the bound runner" do
        before do
          create(:llm_model, :openai, model_id: "gpt-4o", tier: "high")
          # Key preference under "claude" — the effective_runner for a
          # claude_code agent_type — so the tenant preference branch is
          # actually reached before the runner_compatible? guard fires.
          create(:tenant_setting, account: project.account,
            provider_preferences: { "model_preferences" => { "claude" => "gpt-4o" } })
        end

        it "skips the incompatible tenant model" do
          selection = described_class.call(agent_run: cursor_agent_run)

          # The tenant-preferred gpt-4o is incompatible with the cursor
          # runner (anthropic), so it must be skipped — either no selection
          # or a different model.
          if selection
            expect(selection.llm_model.model_id).not_to eq("gpt-4o")
          end
        end
      end
    end
  end
end
