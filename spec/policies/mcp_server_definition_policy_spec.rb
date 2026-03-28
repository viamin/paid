# frozen_string_literal: true

require "rails_helper"

RSpec.describe McpServerDefinitionPolicy do
  subject { described_class.new(user, mcp_server_definition) }

  let(:account) { create(:account) }
  let(:mcp_server_definition) { create(:mcp_server_definition, account: account) }

  context "when user is an owner" do
    let(:user) { create(:user, :owner, account: account) }

    it { is_expected.to be_index }
    it { is_expected.to be_show }
    it { is_expected.to be_create }
    it { is_expected.to be_update }
    it { is_expected.to be_destroy }
  end

  context "when user is an admin" do
    before { create(:user, account: account) } # absorb owner role

    let(:user) { create(:user, :admin, account: account) }

    it { is_expected.to be_index }
    it { is_expected.to be_show }
    it { is_expected.to be_create }
    it { is_expected.to be_update }
    it { is_expected.not_to be_destroy }
  end

  context "when user is a member" do
    before { create(:user, account: account) } # absorb owner role

    let(:user) { create(:user, :member, account: account) }

    it { is_expected.not_to be_index }
    it { is_expected.not_to be_show }
    it { is_expected.not_to be_create }
    it { is_expected.not_to be_update }
    it { is_expected.not_to be_destroy }
  end

  context "when user is a viewer" do
    before { create(:user, account: account) } # absorb owner role

    let(:user) { create(:user, :viewer, account: account) }

    it { is_expected.not_to be_index }
    it { is_expected.not_to be_show }
    it { is_expected.not_to be_create }
    it { is_expected.not_to be_update }
    it { is_expected.not_to be_destroy }
  end

  context "when user is from a different account" do
    subject { described_class.new(other_user, mcp_server_definition) }

    let(:other_account) { create(:account) }
    let(:other_user) { create(:user, :owner, account: other_account) }

    it { is_expected.not_to be_show }
    it { is_expected.not_to be_update }
    it { is_expected.not_to be_destroy }
  end

  describe described_class::Scope do
    subject(:scope) { described_class.new(user, McpServerDefinition).resolve }

    let!(:mcp_server_definition) { create(:mcp_server_definition, account: account) }

    context "when user is an owner" do
      let(:user) { create(:user, :owner, account: account) }

      it "returns all MCP server definitions" do
        expect(scope).to include(mcp_server_definition)
      end
    end

    context "when user is an admin" do
      before { create(:user, account: account) } # absorb owner role

      let(:user) { create(:user, :admin, account: account) }

      it "returns all MCP server definitions" do
        expect(scope).to include(mcp_server_definition)
      end
    end

    context "when user is a member" do
      before { create(:user, account: account) } # absorb owner role

      let(:user) { create(:user, :member, account: account) }

      it "returns no MCP server definitions" do
        expect(scope).to be_empty
      end
    end

    context "when user is a viewer" do
      before { create(:user, account: account) } # absorb owner role

      let(:user) { create(:user, :viewer, account: account) }

      it "returns no MCP server definitions" do
        expect(scope).to be_empty
      end
    end

    context "when user is an owner from a different account" do
      let(:other_account) { create(:account) }
      let(:user) { create(:user, :owner, account: other_account) }

      it "does not include definitions from other accounts" do
        expect(scope).not_to include(mcp_server_definition)
      end

      it "returns only definitions from the user's own account" do
        expect(scope).to be_empty
      end
    end
  end
end
