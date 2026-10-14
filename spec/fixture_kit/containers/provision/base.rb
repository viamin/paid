# frozen_string_literal: true

# @spec TEST-SUITE-011
FixtureKit.define do
  project = create(:project)

  expose(project:)
end
