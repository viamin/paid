# frozen_string_literal: true

FactoryBot.define do
  factory :issue_merge_subscription do
    issue
    user { issue.project.account.users.first || association(:user, account: issue.project.account) }
    subscription_type { IssueMergeSubscription::ON_MERGE }
  end
end
