# frozen_string_literal: true

require "rails_helper"

RSpec.describe StagedCloseoutAdoption::Enroll do
  let(:project) { create(:project) }
  let(:maintainer) { create(:user, :owner, account: project.account) }

  # @spec STAGED-CLOSEOUT-ADOPTION-001
  it "defaults to disabled independently of existing merge automation" do
    project.update!(auto_merge_mode: "all")

    expect(project.staged_closeout_enrollment).to be_nil
    expect(described_class.call(project:, actor: maintainer, enabled: false).enabled).to be(false)
  end

  # @spec STAGED-CLOSEOUT-ADOPTION-002
  it "records the reviewer and supports an explicit later revocation" do
    enabled = described_class.call(project:, actor: maintainer, enabled: true)
    disabled = described_class.call(project:, actor: maintainer, enabled: false)

    expect(enabled).to be_enabled
    expect(disabled).to have_attributes(enabled: false, reviewed_by: maintainer)
    expect(disabled.reviewed_at).to be_present
  end
end
