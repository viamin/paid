# frozen_string_literal: true

FactoryBot.define do
  factory :issue_dependency do
    issue
    depends_on_issue { association :issue, project: issue.project }
  end
end
