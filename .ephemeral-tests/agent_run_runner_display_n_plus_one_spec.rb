# frozen_string_literal: true

# Regression guard for the agent-run "Runner" column N+1.
#
# Several views render a runner display per row by calling
# `agent_run_runner_display(run)` with no precomputed map. That fallback rebuilds
# the lookup via `agent_run_runner_displays([run])` for every row, firing a fresh
# `runners` table query per row. The fix precomputes the map once per table and
# threads it into each row as `runner_displays`.
#
# Covered tables (all loop over agent runs and render the Runner column):
#   - dashboard/_active_runs
#   - projects/agent_runs/_table          (Turbo broadcast, up to 50 rows)
#   - projects/_agent_runs -> _agent_run  (project show page / broadcast)
#
# Rendering each partial in isolation keeps the measurement focused on the
# runner-display path (a full request also queries `runners` from unrelated
# sections like dashboard live stats and the queue preview).

require "rails_helper"

RSpec.describe "Agent-run runner display N+1", type: :view do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:project) { create(:project, account: account, created_by: user) }

  def runners_query_count
    count = 0
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*args|
      payload = args.last
      sql = payload[:sql].to_s
      count += 1 if sql.match?(/\bFROM\s+"runners"/i) && !payload[:cached]
    end
    yield
    count
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber)
  end

  def create_runs(n)
    n.times.map do
      create(
        :agent_run,
        :running,
        project: project,
        # Non-routing-key identifier => exercises configured_runners_for_runs,
        # the helper that issued the per-row `runners` query before the fix.
        final_runner: "cursor"
      )
    end
  end

  # Re-fetch with the same preloading the controllers/broadcasters use so the
  # measurement reflects production query behavior.
  def reload_with_preloads(runs)
    loaded = AgentRun.where(id: runs.map(&:id))
      .includes(:runner, :issue, :model_selection, project: [ :created_by, :account ])
      .to_a
    AgentRun.preload_final_runner_records(loaded)
    loaded
  end

  # Renders the table for 1 row and for 6 rows and asserts the number of
  # `runners` queries does not grow with the row count.
  def expect_constant_runner_queries
    one = create_runs(1)
    baseline = runners_query_count { yield(reload_with_preloads(one)) }

    six = one + create_runs(5)
    scaled = runners_query_count { yield(reload_with_preloads(six)) }

    expect(scaled).to eq(baseline),
      "expected runners-table query count to stay constant as rows grow " \
      "(N+1 regression): #{baseline} with 1 run vs #{scaled} with 6 runs"
  end

  it "dashboard/_active_runs queries runners a constant number of times" do
    expect_constant_runner_queries do |runs|
      render partial: "dashboard/active_runs", locals: { active_runs: runs }
    end
  end

  it "projects/agent_runs/_table queries runners a constant number of times" do
    expect_constant_runner_queries do |runs|
      render partial: "projects/agent_runs/table", locals: { project: project, agent_runs: runs }
    end
  end

  it "projects/_agent_runs queries runners a constant number of times" do
    expect_constant_runner_queries do |runs|
      render partial: "projects/agent_runs",
        locals: { project: project, recent_agent_runs: runs, stale_agent_runs_count: 0 }
    end
  end
end
