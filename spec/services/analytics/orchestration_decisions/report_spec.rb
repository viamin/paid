# frozen_string_literal: true

require "rails_helper"

RSpec.describe Analytics::OrchestrationDecisions::Report do
  around do |example|
    travel_to(Time.zone.local(2026, 5, 7, 12, 0, 0)) { example.run }
  end

  let(:account) { create(:account) }
  let(:project_a) { create(:project, account: account, name: "Alpha") }
  let(:project_b) { create(:project, account: account, name: "Beta") }

  before do
    create_decision_record(
      project: project_a,
      agent_run: create(:agent_run, :completed, project: project_a),
      status: "active",
      tags: %w[Auth API],
      created_at: 2.days.ago
    )

    create_decision_record(
      project: project_a,
      agent_run: create(:agent_run, :failed, project: project_a),
      status: "superseded",
      tags: %w[performance],
      created_at: 1.day.ago
    )

    create_decision_record(
      project: project_b,
      agent_run: create(:agent_run, :timeout, project: project_b),
      status: "reverted",
      tags: [],
      created_at: Time.current
    )

    create_decision_record(
      project: project_b,
      agent_run: create(:agent_run, :completed, project: project_b),
      status: "active",
      tags: %w[auth],
      created_at: 14.days.ago
    )
  end

  def create_decision_record(...)
    create(:decision_record, ...)
  end

  def expected_summary(total_count:, active_count:, superseded_count:, reverted_count:, completed_run_count:, failed_run_count:)
    {
      total_count: total_count,
      active_count: active_count,
      superseded_count: superseded_count,
      reverted_count: reverted_count,
      linked_agent_run_count: total_count,
      completed_run_count: completed_run_count,
      failed_run_count: failed_run_count
    }
  end

  def expected_project(project:, total_count:, decision_type_count:, active_count:, superseded_count:, reverted_count:)
    {
      project_id: project.id,
      project_name: project.name,
      project_full_name: project.full_name,
      total_count: total_count,
      decision_type_count: decision_type_count,
      active_count: active_count,
      superseded_count: superseded_count,
      reverted_count: reverted_count
    }
  end

  def expected_decision_type(decision_type:, total_count:, project_count:, active_count:, completed_run_count:)
    {
      decision_type: decision_type,
      total_count: total_count,
      project_count: project_count,
      active_count: active_count,
      completed_run_count: completed_run_count
    }
  end

  def expected_daily_volume(day:, total_count:, active_count:, superseded_count:, reverted_count:)
    {
      day: day,
      total_count: total_count,
      active_count: active_count,
      superseded_count: superseded_count,
      reverted_count: reverted_count
    }
  end

  def expected_default_decision_types
    [
      expected_decision_type(
        decision_type: "auth",
        total_count: 2,
        project_count: 2,
        active_count: 2,
        completed_run_count: 2
      ),
      expected_decision_type(
        decision_type: "api",
        total_count: 1,
        project_count: 1,
        active_count: 1,
        completed_run_count: 1
      ),
      expected_decision_type(
        decision_type: "performance",
        total_count: 1,
        project_count: 1,
        active_count: 0,
        completed_run_count: 0
      ),
      expected_decision_type(
        decision_type: "uncategorized",
        total_count: 1,
        project_count: 1,
        active_count: 0,
        completed_run_count: 0
      )
    ]
  end

  def expected_default_daily_volume
    [
      expected_daily_volume(
        day: 14.days.ago.to_date,
        total_count: 1,
        active_count: 1,
        superseded_count: 0,
        reverted_count: 0
      ),
      expected_daily_volume(
        day: 2.days.ago.to_date,
        total_count: 1,
        active_count: 1,
        superseded_count: 0,
        reverted_count: 0
      ),
      expected_daily_volume(
        day: 1.day.ago.to_date,
        total_count: 1,
        active_count: 0,
        superseded_count: 1,
        reverted_count: 0
      ),
      expected_daily_volume(
        day: Time.current.to_date,
        total_count: 1,
        active_count: 0,
        superseded_count: 0,
        reverted_count: 1
      )
    ]
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
          total_count: 4,
          active_count: 2,
          superseded_count: 1,
          reverted_count: 1,
          completed_run_count: 2,
          failed_run_count: 2
        )
      )
    end

    it "builds the project rollup" do
      report = described_class.call

      expect(report[:by_project]).to eq([
        expected_project(
          project: project_a,
          total_count: 2,
          decision_type_count: 3,
          active_count: 1,
          superseded_count: 1,
          reverted_count: 0
        ),
        expected_project(
          project: project_b,
          total_count: 2,
          decision_type_count: 2,
          active_count: 1,
          superseded_count: 0,
          reverted_count: 1
        )
      ])
    end

    it "builds the decision-type rollup" do
      report = described_class.call

      expect(report[:by_decision_type]).to eq(expected_default_decision_types)
    end

    it "builds the daily volume rollup" do
      report = described_class.call

      expect(report[:daily_volume]).to eq(expected_default_daily_volume)
    end

    it "filters by time window" do
      report = described_class.call(filters: { from: 3.days.ago, to: Time.current })

      expect(report[:summary]).to eq(
        expected_summary(
          total_count: 3,
          active_count: 1,
          superseded_count: 1,
          reverted_count: 1,
          completed_run_count: 1,
          failed_run_count: 2
        )
      )
      expect(report[:by_project].map { |row| row[:project_name] }).to eq(%w[Alpha Beta])
      expect(report[:by_decision_type].map { |row| row[:decision_type] }).to eq(
        %w[api auth performance uncategorized]
      )
    end

    it "filters by project" do
      report = described_class.call(filters: { project_ids: [ project_b.id ] })

      expect(report[:summary]).to eq(
        expected_summary(
          total_count: 2,
          active_count: 1,
          superseded_count: 0,
          reverted_count: 1,
          completed_run_count: 1,
          failed_run_count: 1
        )
      )
      expect(report[:by_project].pluck(:project_name)).to eq([ "Beta" ])
      expect(report[:by_decision_type].pluck(:decision_type)).to eq(%w[auth uncategorized])
    end

    it "filters the summary by tag-derived decision type, including uncategorized records" do
      report = described_class.call(filters: { decision_types: [ "AUTH", "uncategorized" ] })

      expect(report[:summary]).to eq(
        expected_summary(
          total_count: 3,
          active_count: 2,
          superseded_count: 0,
          reverted_count: 1,
          completed_run_count: 2,
          failed_run_count: 1
        )
      )
    end

    it "filters the type rollup by tag-derived decision type, including uncategorized records" do
      report = described_class.call(filters: { decision_types: [ "AUTH", "uncategorized" ] })

      expect(report[:by_project].pluck(:project_name)).to eq(%w[Beta Alpha])
      expect(report[:by_decision_type]).to eq([
        expected_decision_type(
          decision_type: "auth",
          total_count: 2,
          project_count: 2,
          active_count: 2,
          completed_run_count: 2
        ),
        expected_decision_type(
          decision_type: "uncategorized",
          total_count: 1,
          project_count: 1,
          active_count: 0,
          completed_run_count: 0
        )
      ])
    end
  end
end
