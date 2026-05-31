# frozen_string_literal: true

require "rails_helper"

RSpec.describe Tools::ListAccountMemberships do
  let(:account) { create(:account) }
  let(:owner) { create(:user, :owner, account:) }
  let(:session) { create(:chat_session, account:, created_by: owner) }

  describe "#call" do
    it "lists memberships for the current account" do
      member = create(:user, :member, account:)

      result = described_class.new(user: owner, session:).call

      expect(result.map { |row| row[:email] }).to include(owner.email, member.email)
    end
  end

  describe Tools::InviteAccountMember do
    it "invites a member through the account service" do
      result = described_class.new(user: owner, session:).call(
        email: "new-user@example.com",
        name: "New User",
        role: "member",
        confirmed: true
      )

      expect(result[:email]).to eq("new-user@example.com")
      expect(result[:role]).to eq("member")
    end
  end

  describe Tools::UpdateAccountMembership do
    it "updates a membership role through the account service" do
      member = create(:user, :member, account:)
      membership = account.account_memberships.find_by!(user: member)

      result = described_class.new(user: owner, session:).call(
        membership_id: membership.id,
        role: "admin",
        confirmed: true
      )

      expect(result[:role]).to eq("admin")
      expect(membership.reload.role).to eq("admin")
    end
  end

  describe Tools::RemoveAccountMembership do
    it "removes a membership through the account service" do
      member = create(:user, :member, account:)
      membership = account.account_memberships.find_by!(user: member)

      result = described_class.new(user: owner, session:).call(
        membership_id: membership.id,
        confirmed: true
      )

      expect(result[:id]).to eq(membership.id)
      expect(account.account_memberships.where(id: membership.id)).to be_empty
    end
  end
end
