# frozen_string_literal: true

require "rails_helper"

RSpec.describe Account do
  describe "associations" do
    it { is_expected.to have_many(:users).dependent(:destroy) }
  end

  describe "validations" do
    subject { build(:account) }

    it { is_expected.to validate_presence_of(:name) }
    it { is_expected.to validate_uniqueness_of(:slug) }

    it "requires slug when name is blank" do
      account = described_class.new(name: nil, slug: nil)
      expect(account).not_to be_valid
      expect(account.errors[:slug]).to include("can't be blank")
    end

    it "validates slug format" do
      account = build(:account, slug: "Invalid Slug!")
      expect(account).not_to be_valid
      expect(account.errors[:slug]).to include("can only contain lowercase letters, numbers, and hyphens")
    end

    it "allows valid slug formats" do
      account = build(:account, slug: "valid-slug-123")
      expect(account).to be_valid
    end
  end

  describe "slug generation" do
    it "generates a slug from the name if not provided" do
      account = described_class.new(name: "My Company")
      account.valid?
      expect(account.slug).to eq("my-company")
    end

    it "does not override an existing slug" do
      account = described_class.new(name: "My Company", slug: "custom-slug")
      account.valid?
      expect(account.slug).to eq("custom-slug")
    end

    it "handles duplicate slugs by appending a counter" do
      create(:account, slug: "my-company")
      account = described_class.new(name: "My Company")
      account.valid?
      expect(account.slug).to eq("my-company-1")
    end

    it "increments the counter for multiple duplicates" do
      create(:account, slug: "my-company")
      create(:account, slug: "my-company-1")
      account = described_class.new(name: "My Company")
      account.valid?
      expect(account.slug).to eq("my-company-2")
    end
  end
end
