# frozen_string_literal: true

require "rails_helper"

RSpec.describe OperatorConsole::BasePolicy, :no_db do
  let(:operator) { Struct.new(:operator?).new(true) }
  let(:non_operator) { Struct.new(:operator?).new(false) }
  let(:scope_class) do
    Struct.new(:all_result) do
      def all
        all_result
      end
    end
  end
  let(:scope) { scope_class.new(:scoped_records) }

  it "allows read and update actions for operators but never raw destroy" do
    policy = described_class.new(operator, Account)

    expect(policy.index?).to be(true)
    expect(policy.show?).to be(true)
    expect(policy.update?).to be(true)
    expect(policy.act_on?).to be(true)
    expect(policy.create?).to be(false)
    expect(policy.destroy?).to be(false)
  end

  it "denies non-operators across the base policy surface" do
    policy = described_class.new(non_operator, Account)

    expect(policy.index?).to be(false)
    expect(policy.show?).to be(false)
    expect(policy.update?).to be(false)
    expect(policy.act_on?).to be(false)
  end

  it "resolves full scope only for operators" do
    resolved = described_class::Scope.new(operator, scope).resolve

    expect(resolved).to eq(:scoped_records)
  end

  it "raises for non-operators when resolving scope" do
    expect {
      described_class::Scope.new(non_operator, scope).resolve
    }.to raise_error(Pundit::NotAuthorizedError, "must be operator")
  end

  describe "specialized operator-console policies" do
    it "permits tenant setting creation only for operators" do
      expect(OperatorConsole::TenantSettingPolicy.new(operator, TenantSetting).create?).to be(true)
      expect(OperatorConsole::TenantSettingPolicy.new(non_operator, TenantSetting).create?).to be(false)
    end

    it "permits account membership creation only for operators" do
      expect(OperatorConsole::AccountMembershipPolicy.new(operator, AccountMembership).create?).to be(true)
      expect(OperatorConsole::AccountMembershipPolicy.new(non_operator, AccountMembership).create?).to be(false)
    end

    it "permits project membership creation only for operators" do
      expect(OperatorConsole::ProjectMembershipPolicy.new(operator, ProjectMembership).create?).to be(true)
      expect(OperatorConsole::ProjectMembershipPolicy.new(non_operator, ProjectMembership).create?).to be(false)
    end
  end
end
