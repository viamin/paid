# frozen_string_literal: true

require "rails_helper"

RSpec.describe TrackerConfigurationPolicy do
  describe "permissions" do
    let(:account) { create(:account) }
    let(:owner) { create(:user, account: account) } # first user gets owner role

    describe "#show?" do
      it "permits users in the same account" do
        tracker_config = create(:tracker_configuration, configurable: account)

        expect(described_class.new(owner, tracker_config)).to be_show
      end

      it "does not permit users from a different account" do
        other_account = create(:account)
        other_user = create(:user, account: other_account)
        tracker_config = create(:tracker_configuration, configurable: account)

        expect(described_class.new(other_user, tracker_config)).not_to be_show
      end
    end

    describe "#create?" do
      it "permits owner" do
        tracker_config = build(:tracker_configuration, configurable: account)

        expect(described_class.new(owner, tracker_config)).to be_create
      end

      it "permits member" do
        create(:user, account: account) # absorb owner role
        member = create(:user, :member, account: account)
        tracker_config = build(:tracker_configuration, configurable: account)

        expect(described_class.new(member, tracker_config)).to be_create
      end
    end

    describe "#update?" do
      it "permits owner" do
        tracker_config = create(:tracker_configuration, configurable: account)

        expect(described_class.new(owner, tracker_config)).to be_update
      end

      it "permits admin" do
        create(:user, account: account) # absorb owner role
        admin = create(:user, :admin, account: account)
        tracker_config = create(:tracker_configuration, configurable: account)

        expect(described_class.new(admin, tracker_config)).to be_update
      end

      it "does not permit member" do
        create(:user, account: account) # absorb owner role
        member = create(:user, :member, account: account)
        tracker_config = create(:tracker_configuration, configurable: account)

        expect(described_class.new(member, tracker_config)).not_to be_update
      end
    end

    describe "#destroy?" do
      it "permits owner" do
        tracker_config = create(:tracker_configuration, configurable: account)

        expect(described_class.new(owner, tracker_config)).to be_destroy
      end

      it "permits admin" do
        create(:user, account: account) # absorb owner role
        admin = create(:user, :admin, account: account)
        tracker_config = create(:tracker_configuration, configurable: account)

        expect(described_class.new(admin, tracker_config)).to be_destroy
      end

      it "does not permit member" do
        create(:user, account: account) # absorb owner role
        member = create(:user, :member, account: account)
        tracker_config = create(:tracker_configuration, configurable: account)

        expect(described_class.new(member, tracker_config)).not_to be_destroy
      end
    end
  end
end
