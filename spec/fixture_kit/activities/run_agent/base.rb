# frozen_string_literal: true

# @spec TEST-SUITE-011
FixtureKit.define do
  user = create(:user)
  project = create(:project, account: user.account, created_by: user)

  expose(user:, project:)
end
