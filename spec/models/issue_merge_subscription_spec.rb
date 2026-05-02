# frozen_string_literal: true

require "rails_helper"

RSpec.describe IssueMergeSubscription, type: :model do
  it "defaults the subscription type to on_merge" do
    subscription = build(:issue_merge_subscription, subscription_type: nil)

    subscription.validate

    expect(subscription.subscription_type).to eq("on_merge")
  end

  it "requires the user and issue to belong to the same account" do
    issue = create(:issue)
    other_user = create(:user)
    subscription = build(:issue_merge_subscription, issue: issue, user: other_user)

    expect(subscription).not_to be_valid
    expect(subscription.errors[:user]).to include("must belong to the same account as the issue")
  end
end
