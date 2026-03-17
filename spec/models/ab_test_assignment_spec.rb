# frozen_string_literal: true

require "rails_helper"

RSpec.describe AbTestAssignment do
  describe "associations" do
    it { is_expected.to belong_to(:ab_test) }
    it { is_expected.to belong_to(:ab_test_variant) }
    it { is_expected.to belong_to(:agent_run) }
  end

  describe "validations" do
    it "enforces uniqueness of agent_run per ab_test" do
      assignment = create(:ab_test_assignment)
      duplicate = build(:ab_test_assignment,
        ab_test: assignment.ab_test,
        agent_run: assignment.agent_run)

      expect(duplicate).not_to be_valid
      expect(duplicate.errors[:agent_run_id]).to be_present
    end
  end
end
