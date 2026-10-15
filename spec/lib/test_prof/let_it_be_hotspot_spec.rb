# frozen_string_literal: true

require "rails_helper"
require "test_prof/recipes/rspec/let_it_be"

# @spec TEST-SUITE-011
RSpec.describe TestProf::LetItBe do
  [ "with stable agent execution project", "with stable provisioning project", "with stable PR scanner project" ].each do |name|
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
