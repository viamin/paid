# frozen_string_literal: true

require "rails_helper"

RSpec.describe Issues::DependencyCycles do
  let(:account) { create(:account) }
  let(:project) { create(:project, account:) }

  def graph(numbers)
    numbers.map { |number| create(:issue, project:, github_number: number, github_state: "open") }
  end

  def connect(issues, pairs)
    pairs.each do |from, to|
      create_legacy_issue_dependency(issue: issues.fetch(from), depends_on_issue: issues.fetch(to))
    end
  end

  # @spec AUTO-PICK-QUEUE-014
  [ [ [ 0, 1 ], [ 1, 0 ] ], [ [ 0, 1 ], [ 1, 2 ], [ 2, 0 ] ],
    [ [ 0, 1 ], [ 1, 2 ], [ 2, 3 ], [ 3, 0 ] ], [ [ 0, 1 ], [ 1, 2 ], [ 2, 3 ], [ 3, 4 ], [ 4, 0 ] ],
    [ [ 0, 1 ], [ 1, 0 ], [ 1, 2 ], [ 2, 1 ] ], [ [ 0, 1 ], [ 1, 2 ], [ 2, 0 ], [ 3, 1 ] ] ].each do |edges|
    it "detects persisted cycle shape #{edges.inspect}" do
      issues = graph((0..edges.flatten.max).to_a)
      connect(issues, edges)

      cycle = described_class.call(account:).sole

      expect(cycle.path.first).to eq(cycle.path.last)
      expect(cycle.issues.map(&:github_state)).to all(eq("open"))
    end
  end

  it "reports downstream held issues without treating them as cycle members" do
    issues = graph([ 1, 2, 3 ])
    connect(issues, [ [ 0, 1 ], [ 1, 0 ], [ 2, 0 ] ])

    cycle = described_class.call(account:).sole

    expect(cycle.issues).to contain_exactly(issues[0], issues[1])
    expect(cycle.downstream_issues).to contain_exactly(issues[2])
  end

  # @spec AUTO-PICK-QUEUE-015
  it "carries declaration provenance on each concrete path edge" do
    issues = graph([ 1, 2 ])
    first_url = "https://github.com/acme/repo/issues/1"
    second_url = "https://github.com/acme/repo/issues/2#issuecomment-7"
    create_legacy_issue_dependency(issue: issues[0], depends_on_issue: issues[1],
      declaration_source: "issue_body", declaration_url: first_url)
    create_legacy_issue_dependency(issue: issues[1], depends_on_issue: issues[0],
      declaration_source: "issue_comment", declaration_url: second_url)

    cycle = described_class.call(account:).sole

    expect(cycle.path_edges.map(&:declaration_url)).to contain_exactly(first_url, second_url)
  end

  # @spec AUTO-PICK-QUEUE-017 AUTO-PICK-QUEUE-018
  it "retains every effective edge in a multi-edge strongly connected group" do
    issues = graph([ 1, 2, 3 ])
    connect(issues, [ [ 0, 1 ], [ 1, 2 ], [ 2, 0 ], [ 0, 2 ] ])

    cycle = described_class.call(account:).sole

    expect(cycle.effective_edges.map { |edge| [ edge.from_id, edge.to_id ] }).to contain_exactly(
      [ issues[0].id, issues[1].id ], [ issues[1].id, issues[2].id ],
      [ issues[2].id, issues[0].id ], [ issues[0].id, issues[2].id ]
    )
    expect(cycle.graph_revision).to eq(cycle.occurrence)
  end

  it "keeps accounts isolated and ignores nonblocking targets" do
    other_project = create(:project)
    local = graph([ 1, 2 ])
    other = [ create(:issue, project: other_project), create(:issue, project: other_project) ]
    connect(local, [ [ 0, 1 ], [ 1, 0 ] ])
    create_legacy_issue_dependency(issue: other[0], depends_on_issue: other[1])
    create_legacy_issue_dependency(issue: other[1], depends_on_issue: other[0])
    local[1].update!(paid_state: "completed")

    expect(described_class.call(account:)).to be_empty
  end

  it "reports unavailable database coverage distinctly from an acyclic graph" do
    account
    allow(Issue.connection).to receive(:select_all)
      .and_raise(ActiveRecord::StatementInvalid, "temporarily unavailable")

    expect { described_class.call(account:) }
      .to raise_error(described_class::CoverageUnavailable, /temporarily unavailable/)
  end
end
