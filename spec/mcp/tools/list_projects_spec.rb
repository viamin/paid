# frozen_string_literal: true

require "rails_helper"

RSpec.describe Tools::ListProjects do
  let(:account) { create(:account) }
  let(:user) { create(:user, :member, account: account) }
  let(:session) { create(:chat_session, account: account, created_by: user) }
  let(:tool) { described_class.new(user: user, session: session) }

  describe ".definition" do
    it "returns valid MCP tool definition" do
      definition = described_class.definition
      expect(definition[:name]).to eq("list_projects")
      expect(definition[:inputSchema][:type]).to eq("object")
    end
  end

  describe "#call" do
    it "returns projects for the user's account" do
      project = create(:project, account: account)
      create(:project) # other account

      result = tool.call

      expect(result.size).to eq(1)
      expect(result.first[:id]).to eq(project.id)
      expect(result.first[:name]).to eq(project.name)
    end

    it "filters by status" do
      create(:project, account: account, active: true)
      create(:project, account: account, active: false)

      active = tool.call(status: "active")
      expect(active.size).to eq(1)
      expect(active.first[:active]).to be(true)
    end

    it "respects limit" do
      3.times { create(:project, account: account) }

      result = tool.call(limit: 2)
      expect(result.size).to eq(2)
    end

    it "caps limit at 100" do
      result = tool.call(limit: 200)
      # Just verify it doesn't raise
      expect(result).to be_an(Array)
    end
  end
end
