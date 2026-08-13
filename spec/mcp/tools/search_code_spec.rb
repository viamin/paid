# frozen_string_literal: true

require "rails_helper"

RSpec.describe Tools::SearchCode do
  let(:account) { create(:account) }
  let(:user) { create(:user, :member, account: account) }
  let(:session) { create(:chat_session, account: account, created_by: user) }
  let(:tool) { described_class.new(user: user, session: session) }
  let(:project) { create(:project, account: account) }
  let(:search_results) do
    {
      results: [
        {
          id: "chunk-1",
          artifact_type: "file",
          identifier: "User model",
          scope_path: "app/models/user.rb",
          score: 0.95,
          content: "a" * 600
        }
      ]
    }
  end

  describe "#call" do
    before { allow(Knowledge::ProviderConfiguration).to receive(:for_embedding).and_return(nil) }

    it "maps Knowledge::Search results into the MCP response shape" do
      allow(Knowledge::Search).to receive(:call).and_return(search_results)

      result = tool.call(project_id: project.id, query: "user model", limit: 75)

      expect(Knowledge::Search).to have_received(:call).with(
        project: project,
        query: "user model",
        mode: "hybrid",
        limit: 50
      )
      expect(result).to eq([
        {
          id: "chunk-1",
          artifact_type: "file",
          name: "User model",
          path: "app/models/user.rb",
          score: 0.95,
          content_preview: ("a" * 497) + "..."
        }
      ])
    end

    it "raises for projects outside the user's account" do
      other_project = create(:project)

      expect { tool.call(project_id: other_project.id, query: "test") }
        .to raise_error(ActiveRecord::RecordNotFound)
    end
  end
end
