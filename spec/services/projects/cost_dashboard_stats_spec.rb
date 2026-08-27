# frozen_string_literal: true

require "rails_helper"

RSpec.describe Projects::CostDashboardStats do
  let(:account) { create(:account) }
  let(:project) { create(:project, account: account, total_cost_cents: 5000, total_tokens_used: 100_000) }

  describe ".call" do
    subject(:stats) { described_class.call(project: project) }

    it "returns summary with cost totals" do
      expect(stats[:summary][:total_cost_cents]).to eq(5000)
      expect(stats[:summary][:total_tokens]).to eq(100_000)
    end

    it "calculates today and monthly costs" do
      travel_to(Time.zone.local(2024, 1, 15, 12, 0, 0)) do
        run = create(:agent_run, project: project, status: "completed", cost_cents: 300)
        create(:token_usage, agent_run: run, cost_cents: 300, request_type: "agent")

        result = described_class.call(project: project)
        expect(result[:summary][:cost_today_cents]).to eq(300)
        expect(result[:summary][:cost_this_month_cents]).to eq(300)
      end
    end

    it "separates infrastructure cost from llm cost while exposing total variable cost" do
      travel_to(Time.zone.local(2024, 1, 15, 12, 0, 0)) do
        run = create(:agent_run, project: project, status: "completed", cost_cents: 300,
          provisioning_started_at: 2.hours.ago, completed_at: 1.hour.ago)
        create(:token_usage, agent_run: run, cost_cents: 300, request_type: "agent")
        create_execution_usage(run,
          provisioned_at: 2.hours.ago,
          terminated_at: 1.hour.ago,
          billed_duration_seconds: 3600,
          infra_cost_cents: 120)

        result = described_class.call(project: project)

        expect(result[:summary][:total_cost_cents]).to eq(5000)
        expect(result[:summary][:infrastructure_cost_cents]).to eq(120)
        expect(result[:summary][:total_variable_cost_cents]).to eq(5120)
        expect(result[:summary][:cost_today_cents]).to eq(300)
        expect(result[:summary][:infrastructure_cost_today_cents]).to eq(120)
        expect(result[:summary][:total_variable_cost_today_cents]).to eq(420)
        expect(result[:summary][:infrastructure_cost_this_month_cents]).to eq(120)
        expect(result[:summary][:total_variable_cost_this_month_cents]).to eq(420)
      end
    end

    it "preserves overlap-based infrastructure accounting for terminated and pending runs" do
      travel_to(Time.zone.local(2024, 1, 15, 12, 0, 0)) do
        finished_run = create(:agent_run, project: project, status: "completed", cost_cents: 300,
          provisioning_started_at: Time.zone.local(2024, 1, 14, 23, 0, 0),
          completed_at: Time.zone.local(2024, 1, 15, 1, 0, 0))
        create_execution_usage(finished_run,
          provisioned_at: Time.zone.local(2024, 1, 14, 23, 0, 0),
          terminated_at: Time.zone.local(2024, 1, 15, 1, 0, 0),
          billed_duration_seconds: 7200,
          infra_cost_cents: 240)

        pending_run = create_pending_run

        result = described_class.call(project: project)

        expect(pending_run.execution_usage).to be_nil
        expect(result[:summary][:infrastructure_cost_cents]).to eq(300)
        expect(result[:summary][:infrastructure_cost_today_cents]).to eq(180)
        expect(result[:summary][:infrastructure_cost_this_month_cents]).to eq(300)
      end
    end

    # @spec INFRA-SPEND-001
    it "accrues pending spend for re-provisioned runs whose prior cycle was already recorded" do
      travel_to(Time.zone.local(2024, 1, 15, 12, 0, 0)) do
        # A run that was torn down after an evicted / park cycle (first
        # cycle's billing recorded) and re-provisioned for a new cycle that
        # is still live — the second machine's spend must appear in pending
        # totals instead of silently disappearing from the dashboard until
        # the second cycle's cleanup finally writes its row.
        reprovisioned_run = create(:agent_run, project: project, status: "running",
          provisioning_started_at: 30.minutes.ago,
          started_at: 25.minutes.ago,
          external_metadata: {
            "infrastructure_spend" => { "rate_cents_per_hour" => 120 }
          })
        create_execution_usage(reprovisioned_run,
          provisioned_at: 2.hours.ago,
          terminated_at: 1.hour.ago,
          billed_duration_seconds: 3600,
          infra_cost_cents: 120)

        result = described_class.call(project: project)

        # Historical (first cycle) cost + pending (second cycle) cost for
        # the new machine, which is 30 min at 120 cents/hr = 60 cents.
        expect(result[:summary][:infrastructure_cost_cents]).to eq(180)
        expect(result[:summary][:infrastructure_cost_today_cents]).to eq(180)
        expect(result[:summary][:infrastructure_cost_this_month_cents]).to eq(180)
      end
    end

    # @spec INFRA-SPEND-001
    it "does not double-count re-provisioned runs whose current cycle has been recorded" do
      travel_to(Time.zone.local(2024, 1, 15, 12, 0, 0)) do
        # A run whose first cycle was recorded (evicted) and whose second
        # cycle's recording has already landed — the recorder's folding
        # captures the total cost in the single row, so pending spend
        # contributes nothing.
        run = create(:agent_run, project: project, status: "completed",
          provisioning_started_at: 30.minutes.ago,
          completed_at: 5.minutes.ago,
          external_metadata: {
            "infrastructure_spend" => { "rate_cents_per_hour" => 120 }
          })
        create_execution_usage(run,
          provisioned_at: 30.minutes.ago,
          terminated_at: 5.minutes.ago,
          billed_duration_seconds: 1500,
          infra_cost_cents: 50)

        result = described_class.call(project: project)

        # Only the recorded row contributes (historical path); pending path
        # sees run.provisioning_started_at <= row.terminated_at and excludes
        # it from the overlap-based pending scope.
        expect(result[:summary][:infrastructure_cost_cents]).to eq(50)
      end
    end

    # @spec EXEC-USAGE-007
    # @spec EXEC-USAGE-011
    it "counts the full persisted spend of a folded multi-cycle row" do
      travel_to(Time.zone.local(2024, 1, 15, 12, 0, 0)) do
        # AgentRuns::RecordExecutionUsage folds a prior cycle's spend into the
        # replacement row while scoping provisioned_at/terminated_at to the
        # latest cycle only, so re-pricing the row from its timestamps would
        # silently drop the first machine's 20 cents.
        run = create(:agent_run, project: project, status: "completed",
          provisioning_started_at: 30.minutes.ago,
          completed_at: 5.minutes.ago,
          external_metadata: {
            "infrastructure_spend" => { "rate_cents_per_hour" => 120 }
          })
        create_execution_usage(run,
          provisioned_at: 30.minutes.ago,
          terminated_at: 5.minutes.ago,
          billed_duration_seconds: 2100,
          infra_cost_cents: 70)

        result = described_class.call(project: project)

        expect(result[:summary][:infrastructure_cost_cents]).to eq(70)
        expect(result[:summary][:infrastructure_cost_today_cents]).to eq(70)
        expect(result[:summary][:infrastructure_cost_this_month_cents]).to eq(70)
      end
    end

    # @spec EXEC-USAGE-007
    it "counts the persisted spend of a zero-duration recorded row" do
      travel_to(Time.zone.local(2024, 1, 15, 12, 0, 0)) do
        # A folded row whose latest cycle was torn down in the same instant it
        # was provisioned still carries the prior cycles' spend; proration must
        # not divide by a zero-length lifetime.
        run = create(:agent_run, project: project, status: "completed",
          provisioning_started_at: 10.minutes.ago,
          completed_at: 10.minutes.ago)
        create_execution_usage(run,
          provisioned_at: 10.minutes.ago,
          terminated_at: 10.minutes.ago,
          billed_duration_seconds: 900,
          infra_cost_cents: 30)

        result = described_class.call(project: project)

        expect(result[:summary][:infrastructure_cost_cents]).to eq(30)
        expect(result[:summary][:infrastructure_cost_today_cents]).to eq(30)
      end
    end

    # @spec EXEC-USAGE-007
    # @spec INFRA-SPEND-001
    it "keeps charging rowless completed runs until cleanup records termination" do
      travel_to(Time.zone.local(2024, 1, 15, 12, 0, 0)) do
        create(:agent_run, project: project, status: "completed",
          provisioning_started_at: 2.hours.ago,
          completed_at: 1.hour.ago,
          external_metadata: {
            "infrastructure_spend" => { "rate_cents_per_hour" => 120 }
          })

        result = described_class.call(project: project)

        expect(result[:summary][:infrastructure_cost_cents]).to eq(240)
        expect(result[:summary][:infrastructure_cost_today_cents]).to eq(240)
        expect(result[:summary][:infrastructure_cost_this_month_cents]).to eq(240)
      end
    end

    it "routes pending infrastructure spend through Capacity::InfrastructureSpend with the open-lifetime clamp" do
      allow(Capacity::InfrastructureSpend).to receive(:spent_cents).and_return(240)

      described_class.call(project: project)

      expect(Capacity::InfrastructureSpend).to have_received(:spent_cents).with(
        project: project,
        starts_at: Time.at(0),
        ends_at: kind_of(Time),
        scope_modifier: kind_of(Proc),
        overlap_ends_at_sql: kind_of(String)
      )
    end

    # @spec EXEC-USAGE-003
    it "does not double-count ContainerMetric samples in infrastructure cost" do
      travel_to(Time.zone.local(2024, 1, 15, 12, 0, 0)) do
        run = create(:agent_run, project: project, status: "completed", cost_cents: 100)
        create(:token_usage, agent_run: run, cost_cents: 100, request_type: "agent")
        create(:container_metric,
          agent_run: run,
          container_id: "abc",
          cpu_percent: 50.0,
          memory_bytes: 1024,
          memory_limit_bytes: 4096,
          memory_percent: 25.0,
          recorded_at: 1.hour.ago)

        result = described_class.call(project: project)

        expect(result[:summary][:infrastructure_cost_cents]).to eq(0)
        expect(result[:summary][:infrastructure_cost_today_cents]).to eq(0)
        expect(result[:summary][:infrastructure_cost_this_month_cents]).to eq(0)
      end
    end

    it "calculates average cost per run" do
      create(:agent_run, project: project, status: "completed", cost_cents: 400)
      create(:agent_run, project: project, status: "completed", cost_cents: 600)

      result = described_class.call(project: project)
      expect(result[:summary][:avg_cost_per_run_cents]).to eq(500)
    end

    it "returns cost breakdown by model" do
      run = create(:agent_run, project: project)
      create(:token_usage, agent_run: run, cost_cents: 200, llm_model: "claude-3-opus", request_type: "agent")
      create(:token_usage, agent_run: run, cost_cents: 100, llm_model: "claude-3-haiku", request_type: "agent")

      result = described_class.call(project: project)
      models = result[:cost_by_model].to_h
      expect(models["claude-3-opus"]).to eq(200)
      expect(models["claude-3-haiku"]).to eq(100)
    end

    it "returns a full 30-day daily cost array with zero-filled gaps" do
      travel_to(Time.zone.local(2024, 6, 15, 12, 0, 0)) do
        run = create(:agent_run, project: project)
        create(:token_usage, agent_run: run, cost_cents: 150, request_type: "agent")

        result = described_class.call(project: project)
        daily = result[:daily_costs]
        expect(daily).to be_an(Array)
        expect(daily.length).to eq(30)
        expect(daily.first.first).to eq(Date.new(2024, 5, 17))
        expect(daily.last.first).to eq(Date.new(2024, 6, 15))
        expect(daily.last.last).to eq(150)
        # Days without usage should be zero-filled
        expect(daily[0..28].map(&:last)).to all(eq(0))
      end
    end

    it "returns budget information with usage for daily budgets" do
      create(:cost_budget, :daily, project: project, limit_cents: 1000, current_usage_cents: 500)

      result = described_class.call(project: project)
      expect(result[:budgets].length).to eq(1)
      budget = result[:budgets].first
      expect(budget[:budget_type]).to eq("daily")
      expect(budget[:usage_percent]).to eq(50.0)
      expect(budget[:current_usage_cents]).to eq(500)
      expect(budget[:remaining_cents]).to eq(500)
    end

    it "breaks down cost by outcome" do
      create(:agent_run, project: project, status: "completed", cost_cents: 400,
        tokens_input: 1000, tokens_output: 500, duration_seconds: 60)
      create(:agent_run, project: project, status: "failed", cost_cents: 200,
        tokens_input: 500, tokens_output: 250, duration_seconds: 30)

      result = described_class.call(project: project)
      completed = result[:cost_by_outcome]["completed"]
      other = result[:cost_by_outcome]["other"]

      expect(completed[:run_count]).to eq(1)
      expect(completed[:total_cost_cents]).to eq(400)
      expect(completed[:avg_cost_cents]).to eq(400)

      expect(other[:run_count]).to eq(1)
      expect(other[:total_cost_cents]).to eq(200)
    end

    it "breaks down cost by goal type" do
      create(:agent_run, project: project, status: "completed", goal: "create_pr",
        cost_cents: 500, tokens_input: 2000, tokens_output: 1000, duration_seconds: 120)
      create(:agent_run, project: project, status: "completed", goal: "create_issue",
        cost_cents: 100, tokens_input: 400, tokens_output: 200, duration_seconds: 20)

      result = described_class.call(project: project)
      pr = result[:cost_by_goal]["create_pr"]
      issue = result[:cost_by_goal]["create_issue"]

      expect(pr[:run_count]).to eq(1)
      expect(pr[:total_cost_cents]).to eq(500)
      expect(pr[:avg_cost_cents]).to eq(500)

      expect(issue[:run_count]).to eq(1)
      expect(issue[:total_cost_cents]).to eq(100)
    end

    it "returns zeros for goal types with no runs" do
      result = described_class.call(project: project)
      review = result[:cost_by_goal]["review"]

      expect(review[:run_count]).to eq(0)
      expect(review[:total_cost_cents]).to eq(0)
    end

    it "breaks down cost by tier" do
      low_model = create(:llm_model, tier: "low")
      high_model = create(:llm_model, tier: "high")

      low_run = create(:agent_run, project: project, status: "completed",
        cost_cents: 100, duration_seconds: 30)
      create(:model_selection, agent_run: low_run, llm_model: low_model, tier: "low", selector_type: "rules")

      high_run = create(:agent_run, project: project, status: "completed",
        cost_cents: 500, duration_seconds: 120)
      create(:model_selection, agent_run: high_run, llm_model: high_model, tier: "high", selector_type: "rules")

      result = described_class.call(project: project)
      tier_costs = result[:cost_by_tier]

      expect(tier_costs["low"][:run_count]).to eq(1)
      expect(tier_costs["low"][:total_cost_cents]).to eq(100)
      expect(tier_costs["high"][:run_count]).to eq(1)
      expect(tier_costs["high"][:total_cost_cents]).to eq(500)
      expect(tier_costs["mid"][:run_count]).to eq(0)
    end

    it "returns zeros for tiers with no runs" do
      result = described_class.call(project: project)
      tier_costs = result[:cost_by_tier]

      expect(tier_costs["low"][:run_count]).to eq(0)
      expect(tier_costs["mid"][:run_count]).to eq(0)
      expect(tier_costs["high"][:run_count]).to eq(0)
    end

    it "omits period-based usage fields for per_run budgets" do
      create(:cost_budget, project: project, budget_type: "per_run", limit_cents: 2000)

      result = described_class.call(project: project)
      budget = result[:budgets].first
      expect(budget[:budget_type]).to eq("per_run")
      expect(budget[:limit_cents]).to eq(2000)
      expect(budget).not_to have_key(:usage_percent)
      expect(budget).not_to have_key(:current_usage_cents)
      expect(budget).not_to have_key(:remaining_cents)
    end

    def create_execution_usage(agent_run, provisioned_at:, terminated_at:, billed_duration_seconds:, infra_cost_cents:)
      create(:execution_usage,
        agent_run: agent_run,
        runner_backend: "local",
        provisioned_at: provisioned_at,
        execution_started_at: provisioned_at,
        completed_at: terminated_at,
        terminated_at: terminated_at,
        billed_duration_seconds: billed_duration_seconds,
        termination_reason: "completed",
        infra_cost_cents: infra_cost_cents,
        rate_cents_per_hour: 120)
    end

    def create_pending_run
      create(:agent_run, project: project, status: "running",
        provisioning_started_at: 30.minutes.ago,
        started_at: 25.minutes.ago,
        external_metadata: {
          "infrastructure_spend" => { "rate_cents_per_hour" => 120 }
        })
    end
  end
end
