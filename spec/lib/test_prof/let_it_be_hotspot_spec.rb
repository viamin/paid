# frozen_string_literal: true

require "rails_helper"
require "test_prof/recipes/rspec/let_it_be"

# @spec TEST-SUITE-011
RSpec.describe TestProf::LetItBe do
  [ "with stable agent execution project", "with stable provisioning project", "with stable PR scanner project",
    "with stable agent run request project" ].each do |name|
    context name do
      include_context name

      2.times do |index|
        it "starts example #{index + 1} with the original persisted graph" do
          expect(project.name).not_to eq("changed in an example")
          expect(project.created_by.name).not_to eq("changed in an example")
          expect(project.created_by.account).to eq(project.account)

          project.update!(name: "changed in an example")
          project.created_by.update!(name: "changed in an example")
        end
      end
    end
  end

  # @spec TEST-SUITE-017
  context "with stable agent run request project" do
    include_context "with stable agent run request project"

    2.times do |index|
      it "isolates request configuration and scenario records for example #{index + 1}" do
        expect(project.account).to equal(account)
        expect(project.created_by).to equal(user)
        expect(project.github_token).to equal(github_token)
        expect(github_token.created_by).to equal(user)
        expect(github_token.validation_status).to eq("validated")
        expect(account.users).to contain_exactly(user)
        expect(project.issues).to be_empty
        expect(project.agent_runs).to be_empty
        expect(user.name).not_to eq("changed in an example")

        user.update!(name: "changed in an example")
        create(:agent_run, project: project)
        github_token.update!(validation_status: "validation_failed")
      end
    end
  end

  # @spec TEST-SUITE-013
  context "with stable PR scanner project" do
    include_context "with stable PR scanner project"

    2.times do |index|
      it "restores scanner settings and scenario records for example #{index + 1}" do
        expect(project).to have_attributes(auto_scan_prs: true, max_pr_followup_runs: 3,
          pr_action_labels: [], auto_fix_merge_conflicts: false)
        expect(project.issues).to be_empty

        project.update!(auto_scan_prs: false, max_pr_followup_runs: 1,
          pr_action_labels: [ "scenario-only" ], auto_fix_merge_conflicts: true)
        create(:issue, project: project)
      end
    end
  end
end
