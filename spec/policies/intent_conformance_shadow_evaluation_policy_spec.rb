# frozen_string_literal: true

require "rails_helper"

# @spec INTENT-CONFORMANCE-ROLLOUT-005
# @spec INTENT-CONFORMANCE-ROLLOUT-009
RSpec.describe IntentConformanceShadowEvaluationPolicy do
  let(:account) { create(:account) }
  let(:maintainer) { create(:user, :owner, account: account) }
  let(:member) { create(:user, :member, account: account) }
  let(:project) { create(:project, account: account, created_by: maintainer) }
  let(:evaluation) do
    create(:intent_conformance_shadow_evaluation, project: project, solo_maintainer: maintainer, created_by: maintainer)
  end

  it "lets any account member view the evaluation" do
    expect(described_class.new(member, evaluation)).to be_show
  end

  it "lets account operators start evaluations and trigger execution" do
    expect(described_class.new(member, evaluation)).to be_create
    expect(described_class.new(member, evaluation)).to be_execute
    expect(described_class.new(maintainer, evaluation)).to be_execute
  end

  it "restricts labeling, freezing, and revising to the declared solo maintainer" do
    expect(described_class.new(maintainer, evaluation)).to be_label
    expect(described_class.new(maintainer, evaluation)).to be_freeze
    expect(described_class.new(maintainer, evaluation)).to be_revise

    expect(described_class.new(member, evaluation)).not_to be_label
    expect(described_class.new(member, evaluation)).not_to be_freeze
    expect(described_class.new(member, evaluation)).not_to be_revise
  end

  it "denies users from other accounts (tenant isolation)" do
    outsider = create(:user, :owner, account: create(:account))
    policy = described_class.new(outsider, evaluation)

    expect(policy).not_to be_show
    expect(policy).not_to be_create
    expect(policy).not_to be_label
    expect(policy).not_to be_execute
  end

  it "denies anonymous users" do
    expect(described_class.new(nil, evaluation)).not_to be_show
  end
end
