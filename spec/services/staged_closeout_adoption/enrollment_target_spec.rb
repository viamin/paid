# frozen_string_literal: true

require "rails_helper"

# @spec STAGED-CLOSEOUT-ADOPTION-008
RSpec.describe StagedCloseoutAdoption::EnrollmentTarget do
  let(:account) { create(:account) }
  let(:actor) { create(:user, :owner, account:) }
  let(:project) { create(:project, account:) }

  it "reapplies stale enrollment targets without creating a duplicate enrollment" do
    first_target = described_class.new(project: project.reload, actor:)
    second_target = described_class.new(project: project.reload, actor:)
    first_target.enabled = true
    second_target.enabled = true

    first_target.save!

    expect { second_target.save! }.not_to raise_error
    expect(StagedCloseoutEnrollment.where(project:)).to contain_exactly(be_enabled)
  end
end
