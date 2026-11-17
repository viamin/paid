# frozen_string_literal: true

require "rails_helper"

# @spec STAGED-CLOSEOUT-ADOPTION-008
RSpec.describe StagedCloseoutAdoption::EnrollmentTarget do
  let(:account) { create(:account) }
  let(:actor) { create(:user, :owner, account:) }
  let(:second_actor) { create(:user, :owner, account:) }
  let(:project) { create(:project, account:) }

  it "preserves the first enrollment audit when a stale target is reapplied" do
    first_target = described_class.new(project: project.reload, actor:)
    second_target = described_class.new(project: project.reload, actor: second_actor)
    first_target.enabled = true
    second_target.enabled = true

    enrollment = first_target.save!

    expect { second_target.save! }.not_to raise_error
    expect(StagedCloseoutEnrollment.where(project:)).to contain_exactly(
      have_attributes(enabled: true, reviewed_by: actor, reviewed_at: enrollment.reviewed_at, revision: 1)
    )
  end
end
