# frozen_string_literal: true

require "rails_helper"

RSpec.describe Dashboard::LiveStats do # @spec DASHBOARD-LIVE-STATS-001 DASHBOARD-LIVE-STATS-002 DASHBOARD-LIVE-STATS-003
  around do |example|
    original = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    travel_to(Time.current.beginning_of_day + 12.hours) { example.run }
  ensure
    Rails.cache = original
  end

  it "excludes historical terminal rows from the aggregate's actual database input" do
    project = create(:project)
    create_list(:agent_run, 4, project: project, status: "completed", completed_at: 2.days.ago)
    create(:agent_run, project: project, status: "running", started_at: 3.days.ago)
    payloads = capture_query_payloads { described_class.call(account: project.account) }
    aggregates = payloads.select { |p| p[:sql].include?("COUNT(*) FILTER") }
    expect(aggregates.size).to eq(1)
    query = aggregates.first
    raw = ActiveRecord::Base.connection.exec_query(
      "EXPLAIN (ANALYZE, FORMAT JSON) #{query.fetch(:sql)}", "Live counter input", query.fetch(:binds)
    ).rows.first.first
    plan = raw.is_a?(String) ? JSON.parse(raw) : raw

    expect(input_rows(plan.first.fetch("Plan"))).to eq(1)
  end

  it "keeps old active work and the existing completion-time semantics" do
    project = create(:project)
    create(:agent_run, project: project, status: "running", started_at: 3.days.ago)
    create(:agent_run, project: project, status: "queued", created_at: 3.days.ago)
    create(:agent_run, project: project, status: "completed", completed_at: 1.hour.from_now)
    create(:agent_run, project: project, status: "completed", completed_at: nil)

    expect(described_class.call(account: project.account)).to include(
      active_runs: 1, queued_runs: 1, completed_today: 1, failed_today: 0
    )
  end

  it "keeps active and recent rows from another account out of every counter" do
    project = create(:project)
    other_project = create(:project, account: create(:account))
    create(:agent_run, project: project, status: "running", started_at: 1.hour.ago)
    create(:agent_run, project: project, status: "queued")
    create(:agent_run, project: other_project, status: "running", started_at: 1.hour.ago)
    create(:agent_run, project: other_project, status: "queued")
    create(:agent_run, project: other_project, status: "completed", completed_at: 1.hour.ago)

    expect(described_class.call(account: project.account)).to include(
      active_runs: 1, queued_runs: 1, completed_today: 0, failed_today: 0, active_create_pr_runs: 1
    )
  end

  def input_rows(node)
    own_rows = node["Relation Name"] == "agent_runs" ? node.fetch("Actual Rows") * node.fetch("Actual Loops") : 0
    own_rows + Array(node["Plans"]).sum { |child| input_rows(child) }
  end
end
