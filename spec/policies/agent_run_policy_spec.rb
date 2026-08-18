# frozen_string_literal: true

require "rails_helper"

# Verifies that AgentRun authorization (including access to agent_run_logs,
# which are only ever exposed to a user through Projects::AgentRunsController#show)
# is scoped to the run's own account, not just the record's own presence.
# @spec TENANT-ACCESS-001
# @spec EXECUTION-ISOLATION-005
RSpec.describe AgentRunPolicy do
  describe "#show?" do
    it "permits a user in the run's account" do
      account = create(:account)
      owner = create(:user, account: account)
      project = create(:project, account: account)
      agent_run = create(:agent_run, project: project)

      expect(described_class.new(owner, agent_run)).to be_show
    end

    it "does not permit a user from a different account" do
      account = create(:account)
      project = create(:project, account: account)
      agent_run = create(:agent_run, project: project)
      other_account = create(:account)
      other_user = create(:user, account: other_account)

      expect(described_class.new(other_user, agent_run)).not_to be_show
    end
  end

  describe "#index?" do
    it "does not permit a user from a different account" do
      account = create(:account)
      project = create(:project, account: account)
      agent_run = create(:agent_run, project: project)
      other_account = create(:account)
      other_user = create(:user, account: other_account)

      expect(described_class.new(other_user, agent_run)).not_to be_index
    end
  end

  describe "#cancel?, #retry?, #resume?, #terminate?, #refresh_auth?, #diagnose_error?" do
    it "permits a run-agent-capable user in the run's account" do
      account = create(:account)
      owner = create(:user, account: account)
      project = create(:project, account: account)
      agent_run = create(:agent_run, project: project)

      policy = described_class.new(owner, agent_run)

      expect(policy).to be_cancel
      expect(policy).to be_retry
      expect(policy).to be_resume
      expect(policy).to be_terminate
      expect(policy).to be_refresh_auth
      expect(policy).to be_diagnose_error
    end

    it "does not permit a user from a different account, even with a project role on the same project" do
      account = create(:account)
      project = create(:project, account: account)
      agent_run = create(:agent_run, project: project)
      other_account = create(:account)
      other_user = create(:user, account: other_account)
      other_user.add_role(:project_member, project)

      policy = described_class.new(other_user, agent_run)

      expect(policy).not_to be_cancel
      expect(policy).not_to be_retry
      expect(policy).not_to be_resume
      expect(policy).not_to be_terminate
    end

    it "does not permit an account viewer without a project role" do
      account = create(:account)
      create(:user, account: account) # absorb owner role
      viewer = create(:user, :viewer, account: account)
      project = create(:project, account: account)
      agent_run = create(:agent_run, project: project)

      expect(described_class.new(viewer, agent_run)).not_to be_cancel
    end
  end

  describe "Scope" do
    it "resolves only agent runs whose project belongs to the user's account" do
      account = create(:account)
      user = create(:user, account: account)
      project = create(:project, account: account)
      own_run = create(:agent_run, project: project)

      other_account = create(:account)
      other_project = create(:project, account: other_account)
      create(:agent_run, project: other_project)

      scope = described_class::Scope.new(user, AgentRun).resolve

      expect(scope).to contain_exactly(own_run)
    end
  end
end
