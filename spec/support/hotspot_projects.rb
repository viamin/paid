# frozen_string_literal: true

require "test_prof/recipes/rspec/let_it_be"

# @spec TEST-SUITE-011
# Keep only stable project graphs in the group transaction; issues and runs
# remain per-example so overrides preserve active-run uniqueness constraints.
RSpec.shared_context "with stable agent execution project" do
  let_it_be(:user, refind: true) do
    TenantContext.with_system_access { create(:user) }
  end
  let_it_be(:project, refind: true) do
    TenantContext.with_system_access { create(:project, account: user.account, created_by: user) }
  end

  before do
    project.account = user.account
    project.created_by = user
  end
end

RSpec.shared_context "with stable provisioning project" do
  let_it_be(:project, refind: true) do
    TenantContext.with_system_access { create(:project) }
  end
end

# @spec TEST-SUITE-011, TEST-SUITE-013
RSpec.shared_context "with stable PR scanner project" do
  let_it_be(:project, refind: true) do
    TenantContext.with_system_access do
      create(:project,
        auto_scan_prs: true,
        max_pr_followup_runs: 3,
        pr_action_labels: [],
        auto_fix_merge_conflicts: false)
    end
  end
end
