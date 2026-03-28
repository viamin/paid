# frozen_string_literal: true

require "rails_helper"

RSpec.describe ProjectMcpServer do
  describe "associations" do
    it { is_expected.to belong_to(:project) }
    it { is_expected.to belong_to(:mcp_server_definition) }
  end

  describe "validations" do
    subject { build(:project_mcp_server) }

    it { is_expected.to validate_uniqueness_of(:mcp_server_definition_id).scoped_to(:project_id) }

    it "validates definition belongs to same account as project" do
      account = create(:account)
      other_account = create(:account)
      project = create(:project, account: account)
      definition = create(:mcp_server_definition, account: other_account)

      join = build(:project_mcp_server, project: project, mcp_server_definition: definition)

      expect(join).not_to be_valid
      expect(join.errors[:mcp_server_definition]).to include("must belong to the same account as the project")
    end

    it "is valid when definition belongs to same account" do
      account = create(:account)
      project = create(:project, account: account)
      definition = create(:mcp_server_definition, account: account)

      join = build(:project_mcp_server, project: project, mcp_server_definition: definition)

      expect(join).to be_valid
    end
  end
end
