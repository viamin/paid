# frozen_string_literal: true

require "rails_helper"

RSpec.describe Tools::SearchIssues do
  let(:account) { create(:account) }
  let(:user) { create(:user, :member, account: account) }
  let(:session) { create(:chat_session, account: account, created_by: user) }
  let(:tool) { described_class.new(user: user, session: session) }
  let(:project) { create(:project, account: account) }
  let(:github_client) { instance_double(GithubClient) }
  let(:identity) { "project-token:#{project.github_token.name}" }
  let(:resolved_client) { Tools::RepoReadClientResolver::ResolvedClient.new(client: github_client, identity:) }
  let(:issue_item) { double_issue(number: 42, title: "Duplicate report", state: "open") }

  before do
    allow(tool).to receive(:resolve_repo_read_client).and_return(resolved_client)
  end

  def double_issue(number:, title:, state:, labels: [])
    Struct.new(:number, :title, :state, :labels, :html_url, :created_at, :updated_at).new(
      number, title, state, labels, "https://github.com/owner/repo/issues/#{number}", 1.day.ago, 1.hour.ago
    )
  end

  describe "#call" do
    it "returns zero results" do
      search_result = Struct.new(:total_count, :items).new(0, [])
      allow(github_client).to receive(:search_issues).and_return(search_result)

      result = tool.call(project_id: project.id, query: "nonexistent issue xyz")

      expect(result).to eq(total_count: 0, issues: [], truncated: false, identity: identity)
    end

    it "returns one result" do
      search_result = Struct.new(:total_count, :items).new(1, [ issue_item ])
      allow(github_client).to receive(:search_issues).and_return(search_result)

      result = tool.call(project_id: project.id, query: "duplicate")

      expect(result[:total_count]).to eq(1)
      expect(result[:issues]).to eq([
        {
          github_number: 42,
          title: "Duplicate report",
          github_state: "open",
          labels: [],
          html_url: "https://github.com/owner/repo/issues/42",
          created_at: issue_item.created_at,
          updated_at: issue_item.updated_at
        }
      ])
    end

    it "returns many results" do
      items = (1..3).map { |n| double_issue(number: n, title: "Issue #{n}", state: "open") }
      search_result = Struct.new(:total_count, :items).new(3, items)
      allow(github_client).to receive(:search_issues).and_return(search_result)

      result = tool.call(project_id: project.id, query: "mutant OR mutation")

      expect(result[:issues].map { |i| i[:github_number] }).to eq([ 1, 2, 3 ])
      expect(result[:truncated]).to be(false)
    end

    it "flags truncation when total_count exceeds the requested limit" do
      items = [ issue_item ]
      search_result = Struct.new(:total_count, :items).new(50, items)
      allow(github_client).to receive(:search_issues).and_return(search_result)

      result = tool.call(project_id: project.id, query: "duplicate", limit: 1)

      expect(result[:truncated]).to be(true)
    end

    it "scopes the query to the project's repo and issues only" do
      search_result = Struct.new(:total_count, :items).new(0, [])
      allow(github_client).to receive(:search_issues).and_return(search_result)

      tool.call(project_id: project.id, query: "duplicate")

      expect(github_client).to have_received(:search_issues).with(
        "repo:#{project.full_name} is:issue duplicate", hash_including(:per_page)
      )
    end

    it "includes state and labels qualifiers" do
      search_result = Struct.new(:total_count, :items).new(0, [])
      allow(github_client).to receive(:search_issues).and_return(search_result)

      tool.call(project_id: project.id, query: "duplicate", state: "open", labels: [ "bug", "duplicate" ])

      expect(github_client).to have_received(:search_issues).with(
        "repo:#{project.full_name} is:issue state:open label:\"bug\" label:\"duplicate\" duplicate",
        hash_including(:per_page)
      )
    end

    it "omits the state qualifier when state is 'all'" do
      search_result = Struct.new(:total_count, :items).new(0, [])
      allow(github_client).to receive(:search_issues).and_return(search_result)

      tool.call(project_id: project.id, query: "duplicate", state: "all")

      expect(github_client).to have_received(:search_issues).with(
        "repo:#{project.full_name} is:issue duplicate", hash_including(:per_page)
      )
    end

    it "strips injected repo/org/user qualifiers from the user query" do
      search_result = Struct.new(:total_count, :items).new(0, [])
      allow(github_client).to receive(:search_issues).and_return(search_result)

      tool.call(project_id: project.id, query: "secret repo:other/private-repo org:secret-org user:someone")

      expect(github_client).to have_received(:search_issues).with(
        "repo:#{project.full_name} is:issue secret", hash_including(:per_page)
      )
    end

    it "strips quotes and injected scope qualifiers from label values" do
      search_result = Struct.new(:total_count, :items).new(0, [])
      allow(github_client).to receive(:search_issues).and_return(search_result)

      tool.call(project_id: project.id, query: "duplicate", labels: [ %(bug" repo:other/private-repo) ])

      expect(github_client).to have_received(:search_issues).with(
        "repo:#{project.full_name} is:issue label:\"bug\" duplicate", hash_including(:per_page)
      )
    end

    it "clamps the limit to the configured maximum" do
      search_result = Struct.new(:total_count, :items).new(0, [])
      allow(github_client).to receive(:search_issues).and_return(search_result)

      tool.call(project_id: project.id, query: "duplicate", limit: 500)

      expect(github_client).to have_received(:search_issues).with(anything, per_page: described_class::MAX_RESULTS)
    end

    it "raises for projects outside the user's account" do
      other_project = create(:project)

      expect { tool.call(project_id: other_project.id, query: "duplicate") }
        .to raise_error(ActiveRecord::RecordNotFound)
    end

    it "propagates GitHub API failures" do
      allow(github_client).to receive(:search_issues).and_raise(GithubClient::ApiError.new("boom", status: 500))

      expect { tool.call(project_id: project.id, query: "duplicate") }
        .to raise_error(GithubClient::ApiError, "boom")
    end

    it "propagates rate-limit errors" do
      reset_at = 5.minutes.from_now
      allow(github_client).to receive(:search_issues).and_raise(GithubClient::RateLimitError.new(reset_at))

      expect { tool.call(project_id: project.id, query: "duplicate") }
        .to raise_error(GithubClient::RateLimitError)
    end
  end
end
