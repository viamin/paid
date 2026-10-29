# frozen_string_literal: true

module LegacyDependencyCycleHelper
  def create_legacy_issue_dependency(**attributes)
    dependency = build(:issue_dependency, **attributes)
    dependency.save!(validate: false)
    dependency
  end
end

RSpec.configure do |config|
  config.include LegacyDependencyCycleHelper
end
