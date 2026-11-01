# frozen_string_literal: true

require "rails_helper"

RSpec.describe Tools::RepairDependencyCycle do
  let(:account) { create(:account) }
  let(:user) { create(:user, :member, account:) }
  let(:project) { create(:project, account:) }
  let(:session) { create(:chat_session, account:, created_by: user) }
  let(:github_client) { instance_double(GithubClient) }

  let(:cycle) do
    first = create(:issue, project:, github_state: "open", github_number: 101, body: "## Dependencies\n- #102\n")
    second = create(:issue, project:, github_state: "open", github_number: 102)
    create_legacy_issue_dependency(issue: first, depends_on_issue: second,
      declaration_source: "issue_body", declaration_url: first.github_url)
    create_legacy_issue_dependency(issue: second, depends_on_issue: first,
      declaration_source: "issue_body", declaration_url: second.github_url)
    cycle = Issues::DependencyCycles.call(account: account).sole
    first.update!(body: "## Dependencies\n- ##{cycle.path.second.github_number}\n")
    cycle
  end

  let(:live_body) { "## Dependencies\n- ##{cycle.path.second.github_number}\n" }

  before do
    allow(GithubClient).to receive(:new).and_return(github_client)
    allow(github_client).to receive(:issue) { |_repo, _number| Struct.new(:number, :body).new(0, live_body) }
    allow(github_client).to receive(:authenticated_login).and_return("viamin")
    allow(github_client).to receive(:update_issue) do |_repo, number, **options|
      Struct.new(:number, :body).new(number, options.fetch(:body))
    end
    allow(Issues::UpsertFromGithub).to receive(:call) do |project:, github_issue:, **|
      project.issues.find_by!(github_number: github_issue.number).tap { |issue| issue.update!(body: github_issue.body) }
    end
  end

  describe ".definition" do
    it "advertises the bounded repair contract with a confirmed flag" do
      definition = described_class.definition

      expect(definition[:name]).to eq("repair_dependency_cycle")
      expect(definition[:inputSchema][:required]).to eq(%w[project_id occurrence confirmed])
    end

    it "stays out of the auto-approve tier because it edits dependency semantics" do
      expect(described_class.auto_approve_eligible?).to be(false)
    end
  end

  describe "#call" do
    # @spec AUTO-PICK-QUEUE-021
    it "requires confirmation" do
      expect do
        described_class.new(user:, session:).call(project_id: project.id, occurrence: cycle.occurrence, confirmed: false)
      end.to raise_error(ArgumentError, /Confirmation required/)

      expect(github_client).not_to have_received(:update_issue)
    end

    # @spec AUTO-PICK-QUEUE-021
    it "rejects an occurrence that is no longer present" do
      expect do
        described_class.new(user:, session:).call(project_id: project.id, occurrence: "state:dependency_cycle:gone", confirmed: true)
      end.to raise_error(ArgumentError, /no longer present/)
    end

    # @spec AUTO-PICK-QUEUE-021
    it "applies the bounded repair and returns its outcome" do
      result = described_class.new(user:, session:).call(project_id: project.id, occurrence: cycle.occurrence, confirmed: true)

      expect(result[:status]).to eq("applied")
      expect(result[:occurrence]).to eq(cycle.occurrence)
      expect(result[:edge_id]).to eq(cycle.path_edges.first.id)
      expect(result[:removed_declaration]).to eq("- ##{cycle.path.second.github_number}")
      expect(Issues::DependencyCycles.call(account: account)).to be_empty
    end

    # @spec AUTO-PICK-QUEUE-021
    it "surfaces a refusal outcome instead of raising when the declaration is ambiguous" do
      allow(github_client).to receive(:issue) { |_repo, _number| Struct.new(:number, :body).new(0, "#{live_body}- again ##{cycle.path.second.github_number}\n") }

      result = described_class.new(user:, session:).call(project_id: project.id, occurrence: cycle.occurrence, confirmed: true)

      expect(result[:status]).to eq("declaration_ambiguous")
      expect(result[:message]).to include("multiple")
      expect(github_client).not_to have_received(:update_issue)
    end

    # @spec AUTO-PICK-QUEUE-021
    it "requires manage_issues authority" do
      viewer = create(:user, :viewer, account: account)

      expect do
        described_class.new(user: viewer, session:).call(project_id: project.id, occurrence: cycle.occurrence, confirmed: true)
      end.to raise_error(Pundit::NotAuthorizedError)
    end

    it "requires a trusted human GitHub credential" do
      allow(github_client).to receive(:authenticated_login).and_return("stranger")

      expect do
        described_class.new(user:, session:).call(project_id: project.id, occurrence: cycle.occurrence, confirmed: true)
      end.to raise_error(ArgumentError, /trusted human GitHub credential/)
    end
  end

  describe "registry integration" do
    # @spec AUTO-PICK-QUEUE-021
    it "dispatches the bounded repair through the chat tool surface" do
      result = Tools::Registry.dispatch(name: "repair_dependency_cycle",
        arguments: { "project_id" => project.id, "occurrence" => cycle.occurrence, "confirmed" => true },
        user: user, session: session)

      expect(result[:status]).to eq("applied")
      expect(Issues::DependencyCycles.call(account: account)).to be_empty
    end

    # @spec AUTO-PICK-QUEUE-021
    it "dispatches the bounded repair through the raw MCP surface" do
      result = Tools::Registry.dispatch_mcp(name: "repair_dependency_cycle",
        arguments: { "project_id" => project.id, "occurrence" => cycle.occurrence, "confirmed" => true },
        user: user, session: session)

      expect(result[:status]).to eq("applied")
      expect(github_client).to have_received(:update_issue)
    end

    it "keeps the tool hidden from users without manage_issues authority" do
      viewer = create(:user, :viewer, account: account)

      expect(Tools::Registry.mcp_definitions_for(user: viewer, session: session)
        .map { |definition| definition[:name] }).not_to include("repair_dependency_cycle")
    end
  end
end
