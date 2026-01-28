# frozen_string_literal: true

require "rails_helper"

RSpec.describe User do
  describe "associations" do
    it { is_expected.to belong_to(:account) }
  end

  describe "validations" do
    subject { build(:user) }

    it { is_expected.to validate_presence_of(:email) }
    it { is_expected.to validate_uniqueness_of(:email).case_insensitive }
    it { is_expected.to validate_presence_of(:account) }

    it "validates password length" do
      user = build(:user, password: "short", password_confirmation: "short")
      expect(user).not_to be_valid
      expect(user.errors[:password]).to include("is too short (minimum is 6 characters)")
    end

    it "validates password confirmation" do
      user = build(:user, password: "password123", password_confirmation: "different")
      expect(user).not_to be_valid
      expect(user.errors[:password_confirmation]).to include("doesn't match Password")
    end
  end

  describe "devise modules" do
    it "is database authenticatable" do
      expect(described_class.devise_modules).to include(:database_authenticatable)
    end

    it "is registerable" do
      expect(described_class.devise_modules).to include(:registerable)
    end

    it "is recoverable" do
      expect(described_class.devise_modules).to include(:recoverable)
    end

    it "is rememberable" do
      expect(described_class.devise_modules).to include(:rememberable)
    end

    it "is validatable" do
      expect(described_class.devise_modules).to include(:validatable)
    end
  end
end
