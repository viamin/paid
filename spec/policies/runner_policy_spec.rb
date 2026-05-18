# frozen_string_literal: true

require "rails_helper"

module RunnerPolicySpec
  class UserLike
    attr_reader :id

    def initialize(id:)
      @id = id
    end

    def present? = true
  end

  class RunnerLike
    attr_reader :user_id

    def initialize(user_id:)
      @user_id = user_id
    end
  end

  class ScopeLike
    def kept_only
    end
  end
end

RSpec.describe RunnerPolicy, :no_db do
  let(:scope_class) { RunnerPolicy::Scope }
  let(:record) { instance_double(RunnerPolicySpec::RunnerLike, user_id: 11) }
  let(:owner) { instance_double(RunnerPolicySpec::UserLike, id: 11, present?: true) }
  let(:other_user) { instance_double(RunnerPolicySpec::UserLike, id: 22, present?: true) }

  before do
    allow(record).to receive(:user_id).and_return(11)
  end

  describe "owner actions" do
    it "allows the owner to manage and test the runner" do
      policy = described_class.new(owner, record)

      expect(policy.create?).to be(true)
      expect(policy.update?).to be(true)
      expect(policy.destroy?).to be(true)
      expect(policy.test_agent?).to be(true)
    end

    it "denies non-owners" do
      policy = described_class.new(other_user, record)

      expect(policy.create?).to be(false)
      expect(policy.update?).to be(false)
      expect(policy.destroy?).to be(false)
      expect(policy.test_agent?).to be(false)
    end
  end

  describe "#index?" do
    it "requires an authenticated user" do
      expect(described_class.new(owner, record).index?).to be(true)
      expect(described_class.new(nil, record).index?).to be(false)
    end
  end

  describe RunnerPolicy::Scope do
    it "returns kept runners for the current user" do
      kept_scope = instance_double(ActiveRecord::Relation)
      scope = instance_double(RunnerPolicySpec::ScopeLike)

      allow(scope).to receive(:kept_only).and_return(kept_scope)
      allow(kept_scope).to receive(:where).with(user: owner).and_return(:resolved)

      expect(scope_class.new(owner, scope).resolve).to eq(:resolved)
    end

    it "raises for unauthenticated users" do
      scope = instance_double(RunnerPolicySpec::ScopeLike)

      expect {
        scope_class.new(nil, scope).resolve
      }.to raise_error(Pundit::NotAuthorizedError, "must be logged in")
    end
  end
end
