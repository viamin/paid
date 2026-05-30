# frozen_string_literal: true

require "rails_helper"

RSpec.describe Tools::GrepRepo do
  let(:account) { create(:account) }
  let(:user) { create(:user, :member, account: account) }
  let(:session) { create(:chat_session, account: account, created_by: user) }
  let(:tool) { described_class.new(user: user, session: session) }
  let(:project) { create(:project, account: account) }
  let(:github_client) { instance_double(GithubClient) }

  before do
    allow(GithubClient).to receive(:new).and_return(github_client)
    allow(github_client).to receive(:search_code)
  end

  describe "#call" do
    it "returns search results" do
      items = [
        Struct.new(:path, :name, :html_url).new("app/models/foo.rb", "foo.rb", "https://github.com/owner/repo/blob/main/app/models/foo.rb")
      ]
      search_result = Struct.new(:total_count, :items).new(1, items)
      allow(github_client).to receive(:search_code).and_return(search_result)

      result = tool.call(project_id: project.id, query: "def authorize")

      expect(result[:total_count]).to eq(1)
      expect(result[:matches].size).to eq(1)
      expect(result[:matches].first[:path]).to eq("app/models/foo.rb")
      expect(result[:identity]).to include("project-token")
    end

    it "qualifies query with repo scope" do
      search_result = Struct.new(:total_count, :items).new(0, [])
      allow(github_client).to receive(:search_code).and_return(search_result)

      tool.call(project_id: project.id, query: "def authorize")

      expect(github_client).to have_received(:search_code).with("repo:#{project.full_name} def authorize", hash_including(:per_page))
    end

    it "includes path_filter in query" do
      search_result = Struct.new(:total_count, :items).new(0, [])
      allow(github_client).to receive(:search_code).and_return(search_result)

      tool.call(project_id: project.id, query: "class Foo", path_filter: "app/models")

      expect(github_client).to have_received(:search_code).with("repo:#{project.full_name} class Foo path:app/models", hash_including(:per_page))
    end

    it "returns empty results when no matches" do
      search_result = Struct.new(:total_count, :items).new(0, [])
      allow(github_client).to receive(:search_code).and_return(search_result)

      result = tool.call(project_id: project.id, query: "nonexistent_pattern_xyz")

      expect(result[:matches]).to eq([])
      expect(result[:total_count]).to eq(0)
    end

    it "raises for project in another account" do
      other_project = create(:project)

      expect { tool.call(project_id: other_project.id, query: "test") }
        .to raise_error(ActiveRecord::RecordNotFound)
    end
  end
end
