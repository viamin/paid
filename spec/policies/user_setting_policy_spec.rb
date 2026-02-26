# frozen_string_literal: true

require "rails_helper"

RSpec.describe UserSettingPolicy do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:other_user) { create(:user, account: account) }
  let(:user_setting) { create(:user_setting, user: user) }

  describe "#edit?" do
    it "allows the owner to edit their settings" do
      policy = described_class.new(user, user_setting)
      expect(policy.edit?).to be(true)
    end

    it "denies other users from editing settings" do
      policy = described_class.new(other_user, user_setting)
      expect(policy.edit?).to be(false)
    end

    it "denies unauthenticated users" do
      policy = described_class.new(nil, user_setting)
      expect(policy.edit?).to be(false)
    end
  end

  describe "#update?" do
    it "allows the owner to update their settings" do
      policy = described_class.new(user, user_setting)
      expect(policy.update?).to be(true)
    end

    it "denies other users from updating settings" do
      policy = described_class.new(other_user, user_setting)
      expect(policy.update?).to be(false)
    end
  end
end
