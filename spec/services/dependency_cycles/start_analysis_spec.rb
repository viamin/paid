# frozen_string_literal: true

require "rails_helper"

RSpec.describe DependencyCycles::StartAnalysis do
  # @spec AUTO-PICK-QUEUE-016 AUTO-PICK-QUEUE-017
  it "captures every member and effective component edge without changing declarations" do
    user = create(:user)
    project = create(:project, account: user.account, created_by: user)
    first = create(:issue, project:, github_state: "open", title: "Implementation", body: "Implement phase")
    second = create(:issue, project:, github_state: "open", title: "Validation", body: "Validate phase")
    third = create(:issue, project:, github_state: "open", title: "Release", body: "Release phase")
    create(:issue_dependency, issue: first, depends_on_issue: second, declaration_url: "https://github.test/one")
    create_legacy_issue_dependency(issue: second, depends_on_issue: third)
    create_legacy_issue_dependency(issue: third, depends_on_issue: first)
    cycle = Issues::DependencyCycles.call(account: user.account).sole
    dependencies_before = IssueDependency.order(:id).pluck(:id, :declaration_url)

    context = DependencyCycles::AnalysisContext.call(cycle:, github_client_resolver: ->(_) { nil })

    expect(context.fetch(:members).map { |member| member.fetch(:number) }).to contain_exactly(first.github_number, second.github_number, third.github_number)
    expect(context.fetch(:effective_edges)).to have_attributes(size: 3)
    expect(context.fetch(:effective_edges).map { |edge| edge.fetch(:provenance_coverage) }).to include("available", "unavailable")
    expect(context.fetch(:members).map { |member| member.fetch(:trusted_comments).fetch(:coverage) }).to all(eq("unavailable"))
    expect(IssueDependency.order(:id).pluck(:id, :declaration_url)).to eq(dependencies_before)
  end

  # @spec AUTO-PICK-QUEUE-016
  it "deduplicates an active analysis for the same occurrence and revision" do
    user = create(:user)
    project = create(:project, account: user.account, created_by: user)
    first = create(:issue, project:, github_state: "open")
    second = create(:issue, project:, github_state: "open")
    create(:issue_dependency, issue: first, depends_on_issue: second)
    create_legacy_issue_dependency(issue: second, depends_on_issue: first)
    cycle = Issues::DependencyCycles.call(account: user.account).sole
    resolver = Class.new { def self.call(**) = [ nil, "codex" ] }

    context_builder = Class.new { def self.call(cycle:) = { occurrence: cycle.occurrence, graph_revision: cycle.graph_revision } }
    run = described_class.call(cycle:, user:, runner_resolver: resolver, context_builder:)

    expect(run.external_metadata.dig("cycle_analysis", "graph_revision")).to eq(cycle.graph_revision)
    expect { described_class.call(cycle:, user:, runner_resolver: resolver, context_builder:) }.to raise_error(described_class::ActiveRunExists)
  end
end
