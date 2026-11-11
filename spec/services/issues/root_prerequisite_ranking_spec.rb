# frozen_string_literal: true

require "rails_helper"

RSpec.describe Issues::RootPrerequisiteRanking do
  let(:account) { create(:account) }
  let(:project) { create(:project, account:, auto_pick_enabled: true, active: true) }

  def issue(number, project: self.project)
    create(:issue, project:, github_number: number, github_state: "open", paid_state: "in_progress")
  end

  def depends(dependent, prerequisite)
    create(:issue_dependency, issue: dependent, depends_on_issue: prerequisite)
  end

  # @spec PARTIAL-CLOSEOUT-048
  it "ranks an actionable root by deduplicated direct and transitive queue reach with inspectable paths" do
    root = issue(1)
    middle = issue(2)
    direct = issue(3)
    transitive = issue(4)
    depends(direct, root)
    depends(transitive, middle)
    depends(middle, root)

    ranking = described_class.call(account:, queue_issue_ids: [ direct.id, transitive.id ]).sole

    expect(ranking).to have_attributes(root: root, direct_reach: 1, transitive_reach: 1, total_reach: 2,
      actionable: true)
    expect(ranking.paths.map { |path| path.issues.map(&:id) }).to contain_exactly(
      [ root.id, direct.id ], [ root.id, middle.id, transitive.id ]
    )
    expect(ranking.paths.map(&:completion_alone_makes_runnable)).to all(be(true))
    expect(ranking.paths.map(&:stale)).to all(be(true))
  end

  # @spec PARTIAL-CLOSEOUT-048
  it "continues through a queue issue to include downstream queue work" do
    root = issue(1)
    direct = issue(2)
    transitive = issue(3)
    depends(direct, root)
    depends(transitive, direct)

    ranking = described_class.call(account:, queue_issue_ids: [ direct.id, transitive.id ]).sole

    expect(ranking).to have_attributes(direct_reach: 1, transitive_reach: 1, total_reach: 2)
    expect(ranking.paths.map { |path| path.issues.map(&:id) }).to contain_exactly(
      [ root.id, direct.id ], [ root.id, direct.id, transitive.id ]
    )
  end

  # @spec PARTIAL-CLOSEOUT-048
  it "uses the direct path when queue work is also reachable through a longer path" do
    root = issue(1)
    middle = issue(2)
    blocked = issue(3)
    depends(middle, root)
    depends(blocked, middle)
    depends(blocked, root)

    ranking = described_class.call(account:, queue_issue_ids: [ blocked.id ]).sole

    expect(ranking).to have_attributes(direct_reach: 1, transitive_reach: 0, total_reach: 1)
    expect(ranking.paths.sole.issues).to eq([ root, blocked ])
  end

  # @spec PARTIAL-CLOSEOUT-048
  it "keeps recommend-close queue work as a dependent while filtering non-blocking prerequisites" do
    root = issue(1)
    blocked = issue(2)
    blocked.update!(paid_state: "recommend_close")
    depends(blocked, root)

    ranking = described_class.call(account:, queue_issue_ids: [ blocked.id ]).sole

    expect(ranking.root).to eq(root)
    expect(ranking.paths.sole.issues).to eq([ root, blocked ])
  end

  # @spec PARTIAL-CLOSEOUT-048
  it "does not claim sole unblockability while an undeployed merged PR also blocks the work" do
    root = issue(1)
    blocked = issue(2)
    deployment = create(:issue, :pull_request, project:, github_number: 3, github_state: "closed", paid_state: "completed",
      pr_review_phase: "merged", deployed_at: nil)
    depends(blocked, root)
    create(:issue_dependency, issue: blocked, depends_on_issue: deployment, requires_deployment: true)

    ranking = described_class.call(account:, queue_issue_ids: [ blocked.id ]).sole

    expect(ranking.root).to eq(root)
    expect(ranking.paths.sole.completion_alone_makes_runnable).to be(false)
  end

  # @spec PARTIAL-CLOSEOUT-048
  it "does not treat an undeployed merged PR reached through an external dependency as a blocker" do
    upstream_project = create(:project, account:)
    root = issue(1)
    blocked = issue(2)
    deployment = create(:issue, :pull_request, project: upstream_project, github_number: 3, github_state: "closed",
      paid_state: "completed", pr_review_phase: "merged", deployed_at: nil)
    depends(blocked, root)
    create(:issue_dependency, issue: blocked, depends_on_issue: nil, depends_on_owner: upstream_project.owner,
      depends_on_repo: upstream_project.repo, depends_on_number: deployment.github_number, requires_deployment: true)

    ranking = described_class.call(account:, queue_issue_ids: [ blocked.id ]).sole

    expect(ranking.paths.sole.completion_alone_makes_runnable).to be(true)
  end

  # @spec PARTIAL-CLOSEOUT-048
  it "deduplicates fan-out and marks a necessary root that cannot alone unblock independent work" do
    root = issue(1)
    other_root = issue(2)
    shared = issue(3)
    first = issue(4)
    second = issue(5)
    depends(shared, root)
    depends(first, shared)
    depends(second, shared)
    depends(second, other_root)

    ranking = described_class.call(account:, queue_issue_ids: [ first.id, second.id ]).find { |item| item.root == root }

    expect(ranking).to have_attributes(direct_reach: 0, transitive_reach: 2, total_reach: 2)
    expect(ranking.paths.map(&:downstream_issue)).to contain_exactly(first, second)
    expect(ranking.paths.find { |path| path.downstream_issue == first }).to have_attributes(
      necessary: true, completion_alone_makes_runnable: true
    )
    expect(ranking.paths.find { |path| path.downstream_issue == second }).to have_attributes(
      necessary: true, completion_alone_makes_runnable: false
    )
  end

  # @spec PARTIAL-CLOSEOUT-048
  it "excludes cycles and unresolved external edges while retaining explicit diagnostics" do
    cycle_one = issue(1)
    cycle_two = issue(2)
    blocked = issue(3)
    create_legacy_issue_dependency(issue: cycle_one, depends_on_issue: cycle_two)
    create_legacy_issue_dependency(issue: cycle_two, depends_on_issue: cycle_one)
    depends(blocked, cycle_one)
    create(:issue_dependency, issue: blocked, depends_on_issue: nil,
      depends_on_owner: "outside", depends_on_repo: "missing", depends_on_number: 7)

    result = described_class.call(account:, queue_issue_ids: [ blocked.id ])

    expect(result).to be_empty
    expect(described_class.call(account:, queue_issue_ids: [ blocked.id ]).exclusions).to include(
      a_hash_including(kind: "cycle"), a_hash_including(kind: "unresolved_external")
    )
  end

  # @spec PARTIAL-CLOSEOUT-048
  it "does not report cycles outside the loaded queue graph" do
    root = issue(1)
    blocked = issue(2)
    unrelated_one = issue(3)
    unrelated_two = issue(4)
    depends(blocked, root)
    create_legacy_issue_dependency(issue: unrelated_one, depends_on_issue: unrelated_two)
    create_legacy_issue_dependency(issue: unrelated_two, depends_on_issue: unrelated_one)

    result = described_class.call(account:, queue_issue_ids: [ blocked.id ])

    expect(result.sole.root).to eq(root)
    expect(result.exclusions).to be_empty
  end

  # @spec PARTIAL-CLOSEOUT-048
  it "detects cycles from the bounded loaded graph without an account-wide cycle query" do
    root = issue(1)
    blocked = issue(2)
    depends(blocked, root)
    queries = []
    subscriber = ->(*args) { queries << ActiveSupport::Notifications::Event.new(*args).payload[:sql] }

    ActiveSupport::Notifications.subscribed(subscriber, "sql.active_record") do
      described_class.call(account:, queue_issue_ids: [ blocked.id ])
    end

    account_wide_cycle_queries = queries.grep(
      /\ASELECT "issues"\.\* FROM "issues".*"github_state" = 'open'.*"paid_state" NOT IN/m
    )
    expect(account_wide_cycle_queries).to be_empty
  end

  # @spec PARTIAL-CLOSEOUT-048
  it "does not claim sole unblockability when an independent prerequisite has an excluded blocker" do
    root = issue(1)
    independent = issue(2)
    blocked = issue(3)
    depends(blocked, root)
    depends(blocked, independent)
    create(:issue_dependency, issue: independent, depends_on_issue: nil,
      depends_on_owner: "outside", depends_on_repo: "missing", depends_on_number: 7)

    ranking = described_class.call(account:, queue_issue_ids: [ blocked.id ]).find { |item| item.root == root }

    expect(ranking.paths.sole).to have_attributes(
      necessary: true, completion_alone_makes_runnable: false
    )
  end

  # @spec PARTIAL-CLOSEOUT-048
  it "seeds bounded graph loading from visible queue work" do
    500.times { |number| issue(number + 10) }
    root = issue(1_000)
    blocked = issue(1_001)
    depends(blocked, root)

    ranking = described_class.call(account:, queue_issue_ids: [ blocked.id ]).sole

    expect(ranking).to have_attributes(root: root, direct_reach: 1)
  end

  # @spec PARTIAL-CLOSEOUT-048
  it "reports unavailable coverage instead of ranking a truncated relevant graph" do
    blocked = issue(1)
    500.times { |number| depends(blocked, issue(number + 10)) }

    result = described_class.call(account:, queue_issue_ids: [ blocked.id ])

    expect(result).to be_empty
    expect(result.exclusions).to include(a_hash_including(kind: "graph_coverage_truncated"))
  end

  # @spec PARTIAL-CLOSEOUT-048
  it "does not cross account boundaries" do
    root = issue(1)
    local = issue(2)
    depends(local, root)
    other_project = create(:project, account: create(:account))
    other = issue(3, project: other_project)

    result = described_class.call(account:, queue_issue_ids: [ local.id, other.id ])

    expect(result.map(&:root)).to eq([ root ])
    expect(result.exclusions).to include(a_hash_including(kind: "queue_issue_unavailable", issue_id: other.id))
  end

  # @spec PARTIAL-CLOSEOUT-048
  it "traverses a resolved cross-project edge within the same account" do
    upstream_project = create(:project, account:)
    root = issue(1, project: upstream_project)
    blocked = issue(2)
    depends(blocked, root)

    ranking = described_class.call(account:, queue_issue_ids: [ blocked.id ]).sole

    expect(ranking.root).to eq(root)
    expect(ranking.paths.sole.issues).to eq([ root, blocked ])
  end

  # @spec PARTIAL-CLOSEOUT-048
  it "does not traverse a hidden intermediate between visible work" do
    hidden_project = create(:project, account:)
    root = issue(1)
    hidden_middle = issue(2, project: hidden_project)
    blocked = issue(3)
    depends(blocked, hidden_middle)
    depends(hidden_middle, root)

    result = described_class.call(account:, queue_issue_ids: [ blocked.id ], visible_project_ids: [ project.id ])

    expect(result).to be_empty
  end

  # @spec PARTIAL-CLOSEOUT-048
  it "traverses a resolved still-blocking external edge within the same account" do
    upstream_project = create(:project, account:)
    root = issue(1, project: upstream_project)
    blocked = issue(2)
    create(:issue_dependency, issue: blocked, depends_on_issue: nil,
      depends_on_owner: upstream_project.owner, depends_on_repo: upstream_project.repo, depends_on_number: root.github_number)

    ranking = described_class.call(account:, queue_issue_ids: [ blocked.id ]).sole

    expect(ranking.root).to eq(root)
    expect(ranking.paths.sole.issues).to eq([ root, blocked ])
  end

  # @spec PARTIAL-CLOSEOUT-048
  it "marks human-decision prerequisites as excluded rather than actionable roots" do
    root = issue(1)
    blocked = issue(2)
    depends(blocked, root)
    run = create(:agent_run, :completed, project:, issue: root)
    run.update!(reconciliation: { "assessment" => { "gaps" => [ { "kind" => "human" } ] } })

    result = described_class.call(account:, queue_issue_ids: [ blocked.id ])

    expect(result).to be_empty
    expect(result.exclusions).to include(a_hash_including(kind: "human_decision", issue: root))
  end

  # @spec PARTIAL-CLOSEOUT-048
  it "batches persisted assessment reads across the bounded graph" do
    root = issue(1)
    blocked = issue(2)
    depends(blocked, root)
    8.times { |number| issue(number + 10) }
    queries = []
    subscriber = ->(*args) { queries << ActiveSupport::Notifications::Event.new(*args).payload[:sql] }

    ActiveSupport::Notifications.subscribed(subscriber, "sql.active_record") do
      described_class.call(account:, queue_issue_ids: [ blocked.id ])
    end

    expect(queries.grep(/FROM "agent_runs".*reconciliation \? 'assessment'/m).size).to eq(1)
  end

  # @spec PARTIAL-CLOSEOUT-048
  it "evaluates admission only for roots that can appear in the bounded ranking" do
    queue_issue_ids = 12.times.flat_map do |project_number|
      candidate_project = create(:project, account:, auto_pick_enabled: true, active: true)
      root = issue((project_number * 100) + 1, project: candidate_project)
      (project_number + 1).times.map do |reach_number|
        issue((project_number * 100) + reach_number + 2, project: candidate_project).tap do |blocked|
          depends(blocked, root)
        end.id
      end
    end
    queries = []
    subscriber = ->(*args) { queries << ActiveSupport::Notifications::Event.new(*args).payload[:sql] }

    result = ActiveSupport::Notifications.subscribed(subscriber, "sql.active_record") do
      described_class.call(account:, queue_issue_ids:)
    end

    expect(result.rankings.size).to eq(described_class::MAX_RANKED_ROOTS)
    expect(queries.grep(/FROM "design_amendment_pauses"/).size).to be <= described_class::MAX_RANKED_ROOTS
  end

  # @spec PARTIAL-CLOSEOUT-048
  it "loads a maximum-depth linear graph in a bounded number of queries" do
    chain = 500.times.map { |number| issue(number + 1) }
    chain.each_cons(2) { |prerequisite, dependent| depends(dependent, prerequisite) }
    queries = []
    subscriber = lambda do |*args|
      payload = ActiveSupport::Notifications::Event.new(*args).payload
      queries << payload[:sql] if payload[:name] != "SCHEMA" && payload[:sql].start_with?("SELECT")
    end

    result = ActiveSupport::Notifications.subscribed(subscriber, "sql.active_record") do
      described_class.call(account:, queue_issue_ids: [ chain.last.id ])
    end

    expect(result.sole.root).to eq(chain.first)
    expect(queries.size).to be <= 40
  end

  # @spec PARTIAL-CLOSEOUT-048
  it "counts every reachable queue issue while bounding rendered path samples" do
    root = issue(1)
    blocked = 30.times.map do |number|
      issue(number + 10).tap { |downstream| depends(downstream, root) }
    end

    ranking = described_class.call(account:, queue_issue_ids: blocked.map(&:id)).sole

    expect(ranking).to have_attributes(direct_reach: 30, transitive_reach: 0, total_reach: 30)
    expect(ranking.paths.size).to eq(described_class::MAX_PATHS_PER_ROOT)
  end
end
