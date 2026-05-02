# frozen_string_literal: true

require "rails_helper"

RSpec.describe Tools::Registry do
  describe ".definitions_for" do
    it "includes write tools for a user with a project-level member role" do
      account = create(:account)
      project = create(:project, account: account)
      user = create(:user, :viewer, account: account)
      create(:project_membership, :member, user: user, project: project)

      definitions = described_class.definitions_for(user: user)

      expect(definitions.map { |definition| definition[:name] }).to include("trigger_agent_run", "cancel_agent_run")
    end
  end
end
