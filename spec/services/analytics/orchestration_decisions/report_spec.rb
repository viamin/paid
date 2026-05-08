# frozen_string_literal: true

require "rails_helper"

RSpec.describe Analytics::OrchestrationDecisions::Report do
  around do |example|
    travel_to(Time.zone.local(2026, 5, 7, 12, 0, 0)) { example.run }
  end

  let(:account) { create(:account) }
  let(:project_a) { create(:project, account: account, name: "Alpha") }
  let(:project_b) { create(:project, account: account, name: "Beta") }
  let(:completed_select_agent_run) { create(:agent_run, :completed, project: project_b) }

  before do
    create_decision(
      project: project_a,
      agent_run: create(:agent_run, :completed, project: project_a),
      decision_type: "planning_outcome",
      actor: "Workflows::PlanningWorkflow",
      context: { decision_status: "applied" },
      created_at: 2.days.ago
    )

    create_decision(
      project: project_a,
      agent_run: create(:agent_run, :failed, project: project_a),
      decision_type: "retry",
      actor: "timeout_auto_retry",
      context: { decision_status: "failed" },
      created_at: 1.day.ago
    )

    create_decision(
      project: project_b,
      agent_run: create(:agent_run, :timeout, project: project_b),
      decision_type: "select_agent",
      actor: "model_selection",
      context: { decision_status: "noop" },
      created_at: Time.current
    )

    create_decision(
      project: project_b,
      agent_run: completed_select_agent_run,
      decision_type: "select_agent",
      actor: "rules",
      context: { decision_status: "applied" },
      created_at: 14.days.ago
    )

    create_decision(
      project: project_b,
      agent_run: completed_select_agent_run,
      decision_type: "select_agent",
      actor: "fallback_rules",
      context: { decision_status: "applied" },
      created_at: 13.days.ago
    )
  end

  def create_decision(...)
    create(:orchestration_decision, ...)
  end

  def expected_summary(total_count:, applied_count:, noop_count:, failed_count:, linked_agent_run_count:, completed_run_count:, failed_run_count:, project_count:, actor_count:)
    {
      total_count: total_count,
      applied_count: applied_count,
      noop_count: noop_count,
      failed_count: failed_count,
      linked_agent_run_count: linked_agent_run_count,
      completed_run_count: completed_run_count,
      failed_run_count: failed_run_count,
      project_count: project_count,
      actor_count: actor_count
    }
  end

  def expected_project(project:, total_count:, decision_type_count:, actor_count:, applied_count:, noop_count:, failed_count:)
    {
      project_id: project.id,
      project_name: project.name,
      project_full_name: project.full_name,
      total_count: total_count,
      decision_type_count: decision_type_count,
      actor_count: actor_count,
      applied_count: applied_count,
      noop_count: noop_count,
      failed_count: failed_count
    }
  end

  def expected_decision_type(decision_type:, total_count:, project_count:, actor_count:, failed_count:, completed_run_count:)
    {
      decision_type: decision_type,
      total_count: total_count,
      project_count: project_count,
      actor_count: actor_count,
      failed_count: failed_count,
      completed_run_count: completed_run_count
    }
  end

  def expected_daily_volume(day:, total_count:, applied_count:, noop_count:, failed_count:)
    {
      day: day,
      total_count: total_count,
      applied_count: applied_count,
      noop_count: noop_count,
      failed_count: failed_count
    }
  end

  def expected_project_rollup
    [
      expected_project(
        project: project_b,
        total_count: 3,
        decision_type_count: 1,
        actor_count: 3,
        applied_count: 2,
        noop_count: 1,
        failed_count: 0
      ),
      expected_project(
        project: project_a,
        total_count: 2,
        decision_type_count: 2,
        actor_count: 2,
        applied_count: 1,
        noop_count: 0,
        failed_count: 1
      )
    ]
  end

  def expected_decision_type_rollup
    [
      expected_decision_type(
        decision_type: "select_agent",
        total_count: 3,
        project_count: 1,
        actor_count: 3,
        failed_count: 0,
        completed_run_count: 1
      ),
      expected_decision_type(
        decision_type: "planning_outcome",
        total_count: 1,
        project_count: 1,
        actor_count: 1,
        failed_count: 0,
        completed_run_count: 1
      ),
      expected_decision_type(
        decision_type: "retry",
        total_count: 1,
        project_count: 1,
        actor_count: 1,
        failed_count: 1,
        completed_run_count: 0
      )
    ]
  end

  def expected_daily_volume_rollup
    [
      expected_daily_volume(
        day: 14.days.ago.to_date,
        total_count: 1,
        applied_count: 1,
        noop_count: 0,
        failed_count: 0
      ),
      expected_daily_volume(
        day: 13.days.ago.to_date,
        total_count: 1,
        applied_count: 1,
        noop_count: 0,
        failed_count: 0
      ),
      expected_daily_volume(
        day: 2.days.ago.to_date,
        total_count: 1,
        applied_count: 1,
        noop_count: 0,
        failed_count: 0
      ),
      expected_daily_volume(
        day: 1.day.ago.to_date,
        total_count: 1,
        applied_count: 0,
        noop_count: 0,
        failed_count: 1
      ),
      expected_daily_volume(
        day: Time.current.to_date,
        total_count: 1,
        applied_count: 0,
        noop_count: 1,
        failed_count: 0
      )
    ]
  end

  def expected_select_agent_summary
    expected_summary(
      total_count: 3,
      applied_count: 2,
      noop_count: 1,
      failed_count: 0,
      linked_agent_run_count: 2,
      completed_run_count: 1,
      failed_run_count: 1,
      project_count: 1,
      actor_count: 3
    )
  end

  describe ".call" do
    it "returns the initial question set" do
      report = described_class.call

      expect(report[:questions].map { |question| question[:key] }).to eq(
        %w[
          decision_volume_over_time
          decision_mix_by_type
          project_level_decision_patterns
          decision_outcomes
        ]
      )
    end

    it "builds the summary rollup" do
      report = described_class.call

      expect(report[:summary]).to eq(
        expected_summary(
          total_count: 5,
          applied_count: 3,
          noop_count: 1,
          failed_count: 1,
          linked_agent_run_count: 4,
          completed_run_count: 2,
          failed_run_count: 2,
          project_count: 2,
          actor_count: 5
        )
      )
    end

    it "builds the project rollup" do
      expect(described_class.call[:by_project]).to eq(expected_project_rollup)
    end

    it "builds the decision-type rollup" do
      expect(described_class.call[:by_decision_type]).to eq(expected_decision_type_rollup)
    end

    it "builds the daily volume rollup" do
      expect(described_class.call[:daily_volume]).to eq(expected_daily_volume_rollup)
    end

    it "filters by time window" do
      report = described_class.call(filters: { from: 3.days.ago, to: Time.current })

      expect(report[:summary]).to eq(
        expected_summary(
          total_count: 3,
          applied_count: 1,
          noop_count: 1,
          failed_count: 1,
          linked_agent_run_count: 3,
          completed_run_count: 1,
          failed_run_count: 2,
          project_count: 2,
          actor_count: 3
        )
      )
      expect(report[:by_project].map { |row| row[:project_name] }).to eq(%w[Alpha Beta])
      expect(report[:by_decision_type].map { |row| row[:decision_type] }).to eq(
        %w[planning_outcome retry select_agent]
      )
    end

    it "filters by project" do
      report = described_class.call(filters: { project_ids: [ project_b.id ] })

      expect(report[:summary]).to eq(
        expected_summary(
          total_count: 3,
          applied_count: 2,
          noop_count: 1,
          failed_count: 0,
          linked_agent_run_count: 2,
          completed_run_count: 1,
          failed_run_count: 1,
          project_count: 1,
          actor_count: 3
        )
      )
      expect(report[:by_project].pluck(:project_name)).to eq([ "Beta" ])
      expect(report[:by_decision_type].pluck(:decision_type)).to eq([ "select_agent" ])
    end

    it "filters by decision type" do
      report = described_class.call(filters: { decision_types: [ "SELECT_AGENT" ] })

      expect(report[:summary]).to eq(expected_select_agent_summary)
      expect(report[:by_project].pluck(:project_name)).to eq([ "Beta" ])
      expect(report[:by_decision_type]).to eq([ expected_decision_type_rollup.first ])
    end
  end
end
