# frozen_string_literal: true

require "rails_helper"

RSpec.describe CycleRepairs::Apply do
  let(:account) { create(:account) }
  let(:user) { create(:user, :member, account:) }
  let(:github_client) { instance_double(GithubClient) }

  def issue_body(issue, cycle_edges)
    declarations = cycle_edges.select { |edge| edge.from_id == issue.id }
      .map { |edge| "- ##{Issue.find(edge.to_id).github_number}" }
    "## Dependencies\n#{declarations.join("\n")}\n"
  end

  def stub_live_bodies(cycle)
    allow(github_client).to receive(:issue) do |_repo, number|
      issue = cycle.issues.find { |candidate| candidate.github_number == number }
      Struct.new(:body).new(issue_body(issue, cycle.effective_edges))
    end
  end

  def stub_trusted_mutation
    allow(github_client).to receive(:authenticated_login).and_return("viamin")
    allow(github_client).to receive(:update_issue) do |_repo, number, **options|
      Struct.new(:number, :body).new(number, options.fetch(:body))
    end
    allow(Issues::UpsertFromGithub).to receive(:call) do |project:, github_issue:, **|
      project.issues.find_by!(github_number: github_issue.number).tap do |issue|
        issue.update!(body: github_issue.body)
      end
    end
  end

  before do
    allow(GithubClient).to receive(:new).and_return(github_client)
    allow(github_client).to receive(:update_issue)
  end

  def two_issue_cycle(account:, first_source: "issue_body", second_source: "issue_body")
    project = create(:project, account: account)
    first = create(:issue, project:, github_state: "open", github_number: 101)
    second = create(:issue, project:, github_state: "open", github_number: 102)
    create_legacy_issue_dependency(issue: first, depends_on_issue: second,
      declaration_source: first_source, declaration_url: first.github_url)
    create_legacy_issue_dependency(issue: second, depends_on_issue: first,
      declaration_source: second_source, declaration_url: second.github_url)
    Issues::DependencyCycles.call(account: account).sole
  end

  # @spec AUTO-PICK-QUEUE-021
  it "applies the bounded first-path repair, edits one live declaration line, and reconciles the local graph" do
    cycle = two_issue_cycle(account: account)
    stub_live_bodies(cycle)
    stub_trusted_mutation
    edge = cycle.path_edges.first
    from_issue = cycle.path.first
    to_issue = cycle.path.second
    from_issue.update!(body: issue_body(from_issue, cycle.effective_edges))

    result = described_class.call(cycle:, actor: user)

    expect(result.status).to eq(:applied)
    expect(result.edge_id).to eq(edge.id)
    expect(result.removed_declaration).to eq("- ##{to_issue.github_number}")
    edited_body = from_issue.reload.body
    expect(edited_body).not_to include("##{to_issue.github_number}")
    expect(github_client).to have_received(:update_issue)
      .with(from_issue.project.full_name, from_issue.github_number, body: edited_body)
    expect(IssueDependency.exists?(edge.id)).to be(false)
    expect(Issues::DependencyCycles.call(account: account)).to be_empty
  end

  # @spec AUTO-PICK-QUEUE-021
  it "refuses an edge whose declaration is a comment" do
    cycle = two_issue_cycle(account: account, first_source: "issue_comment", second_source: "issue_comment")
    stub_live_bodies(cycle)

    result = described_class.call(cycle:, actor: user)

    expect(result.status).to eq(:edge_not_repairable)
    expect(result.message).to include("comment")
    expect(github_client).not_to have_received(:update_issue)
  end

  # @spec AUTO-PICK-QUEUE-021
  it "reports a missing live declaration without editing GitHub" do
    cycle = two_issue_cycle(account: account)
    allow(github_client).to receive(:issue) { |_repo, _number| Struct.new(:body).new("## Dependencies\n- #9\n") }
    allow(github_client).to receive(:authenticated_login).and_return("viamin")

    result = described_class.call(cycle:, actor: user)

    expect(result.status).to eq(:declaration_missing)
    expect(result.message).to include("no longer declared")
    expect(github_client).not_to have_received(:update_issue)
  end

  # @spec AUTO-PICK-QUEUE-021
  it "ignores child-issue listing content when matching live declarations" do
    cycle = two_issue_cycle(account: account)
    to_number = cycle.path.second.github_number
    allow(github_client).to receive(:issue) { |_repo, _number| Struct.new(:body).new("## Child Issues\n- ##{to_number}\n") }
    allow(github_client).to receive(:authenticated_login).and_return("viamin")

    result = described_class.call(cycle:, actor: user)

    expect(result.status).to eq(:declaration_missing)
    expect(github_client).not_to have_received(:update_issue)
  end

  # @spec AUTO-PICK-QUEUE-021
  it "reports an ambiguous declaration when several lines declare the dependency" do
    cycle = two_issue_cycle(account: account)
    to_number = cycle.path.second.github_number
    allow(github_client).to receive(:issue) { |_repo, _number| Struct.new(:body).new("## Dependencies\n- ##{to_number}\n- ##{to_number} again\n") }
    allow(github_client).to receive(:authenticated_login).and_return("viamin")

    result = described_class.call(cycle:, actor: user)

    expect(result.status).to eq(:declaration_ambiguous)
    expect(result.message).to include("multiple")
    expect(github_client).not_to have_received(:update_issue)
  end

  # @spec AUTO-PICK-QUEUE-021
  it "reports an ambiguous declaration when the ref cannot be removed without touching other declarations" do
    cycle = two_issue_cycle(account: account)
    to_number = cycle.path.second.github_number
    allow(github_client).to receive(:issue) { |_repo, _number| Struct.new(:body).new("## Dependencies\n- ##{to_number} #201\n") }
    allow(github_client).to receive(:authenticated_login).and_return("viamin")

    result = described_class.call(cycle:, actor: user)

    expect(result.status).to eq(:declaration_ambiguous)
    expect(github_client).not_to have_received(:update_issue)
  end

  # @spec AUTO-PICK-QUEUE-021
  it "refuses the repair when removing the first path edge leaves the group strongly connected" do
    account = create(:account)
    project = create(:project, account: account)
    alpha = create(:issue, project:, github_state: "open", github_number: 201)
    beta = create(:issue, project:, github_state: "open", github_number: 202)
    gamma = create(:issue, project:, github_state: "open", github_number: 203)
    create_legacy_issue_dependency(issue: alpha, depends_on_issue: beta, declaration_source: "issue_body")
    create_legacy_issue_dependency(issue: alpha, depends_on_issue: gamma, declaration_source: "issue_body")
    create_legacy_issue_dependency(issue: gamma, depends_on_issue: beta, declaration_source: "issue_body")
    create_legacy_issue_dependency(issue: beta, depends_on_issue: alpha, declaration_source: "issue_body")
    cycle = Issues::DependencyCycles.call(account: account).sole
    stub_live_bodies(cycle)
    allow(github_client).to receive(:authenticated_login).and_return("viamin")

    result = described_class.call(cycle:, actor: user)

    expect(result.status).to eq(:cycle_unresolved)
    expect(result.message).to include("cycle among")
    expect(github_client).not_to have_received(:update_issue)
    expect(cycle.effective_edges.map(&:id)).to all(be > 0)
  end

  # @spec AUTO-PICK-QUEUE-021
  it "requires a trusted human GitHub credential for the mutation" do
    cycle = two_issue_cycle(account: account)
    stub_live_bodies(cycle)
    allow(github_client).to receive(:authenticated_login).and_return("stranger")

    expect { described_class.call(cycle:, actor: user) }.to raise_error(ArgumentError, /trusted human GitHub credential/)
    expect(github_client).not_to have_received(:update_issue)
  end
end
