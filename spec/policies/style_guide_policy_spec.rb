# frozen_string_literal: true

require "rails_helper"

RSpec.describe StyleGuidePolicy do
  describe "permissions" do
    describe "#index?" do
      it "permits any authenticated user" do
        account = create(:account)
        user = create(:user, account: account)
        guide = create(:style_guide, :for_account, account: account)

        expect(described_class.new(user, guide)).to be_index
      end

      it "does not permit nil user" do
        guide = create(:style_guide, :global)

        expect(described_class.new(nil, guide)).not_to be_index
      end
    end

    describe "#show?" do
      it "permits viewing global style guides" do
        account = create(:account)
        user = create(:user, account: account)
        guide = create(:style_guide, :global)

        expect(described_class.new(user, guide)).to be_show
      end

      it "permits viewing account style guides for same account" do
        account = create(:account)
        user = create(:user, account: account)
        guide = create(:style_guide, :for_account, account: account)

        expect(described_class.new(user, guide)).to be_show
      end

      it "does not permit viewing other account style guides" do
        account = create(:account)
        user = create(:user, account: account)
        other_account = create(:account)
        guide = create(:style_guide, :for_account, account: other_account)

        expect(described_class.new(user, guide)).not_to be_show
      end
    end

    describe "#create?" do
      it "permits owner" do
        account = create(:account)
        owner = create(:user, account: account)
        guide = build(:style_guide, account: account)

        expect(described_class.new(owner, guide)).to be_create
      end

      it "permits admin" do
        account = create(:account)
        create(:user, account: account)
        admin = create(:user, :admin, account: account)
        guide = build(:style_guide, account: account)

        expect(described_class.new(admin, guide)).to be_create
      end

      it "does not permit member" do
        account = create(:account)
        create(:user, account: account)
        member = create(:user, :member, account: account)
        guide = build(:style_guide, account: account)

        expect(described_class.new(member, guide)).not_to be_create
      end

      it "does not permit creating global style guides" do
        account = create(:account)
        owner = create(:user, account: account)
        guide = build(:style_guide, :global)

        expect(described_class.new(owner, guide)).not_to be_create
      end
    end

    describe "#update?" do
      it "permits owner for account style guide" do
        account = create(:account)
        owner = create(:user, account: account)
        guide = create(:style_guide, :for_account, account: account)

        expect(described_class.new(owner, guide)).to be_update
      end

      it "does not permit updating global style guides" do
        account = create(:account)
        owner = create(:user, account: account)
        guide = create(:style_guide, :global)

        expect(described_class.new(owner, guide)).not_to be_update
      end
    end

    describe "#destroy?" do
      it "permits owner for account style guide" do
        account = create(:account)
        owner = create(:user, account: account)
        guide = create(:style_guide, :for_account, account: account)

        expect(described_class.new(owner, guide)).to be_destroy
      end

      it "does not permit destroying global style guides" do
        account = create(:account)
        owner = create(:user, account: account)
        guide = create(:style_guide, :global)

        expect(described_class.new(owner, guide)).not_to be_destroy
      end

      it "does not permit admin to destroy" do
        account = create(:account)
        create(:user, account: account)
        admin = create(:user, :admin, account: account)
        guide = create(:style_guide, :for_account, account: account)

        expect(described_class.new(admin, guide)).not_to be_destroy
      end
    end

    describe "#compress?" do
      it "permits owner for account style guide" do
        account = create(:account)
        owner = create(:user, account: account)
        guide = create(:style_guide, :for_account, account: account)

        expect(described_class.new(owner, guide)).to be_compress
      end

      it "does not permit compressing global style guides" do
        account = create(:account)
        owner = create(:user, account: account)
        guide = create(:style_guide, :global)

        expect(described_class.new(owner, guide)).not_to be_compress
      end
    end
  end

  describe "Scope" do
    it "returns global and account style guides" do
      account = create(:account)
      user = create(:user, account: account)
      global_guide = create(:style_guide, :global)
      account_guide = create(:style_guide, :for_account, account: account)
      other_account = create(:account)
      other_guide = create(:style_guide, :for_account, account: other_account)

      scope = described_class::Scope.new(user, StyleGuide).resolve

      expect(scope).to include(global_guide)
      expect(scope).to include(account_guide)
      expect(scope).not_to include(other_guide)
    end

    it "raises error when user is not logged in" do
      expect {
        described_class::Scope.new(nil, StyleGuide).resolve
      }.to raise_error(Pundit::NotAuthorizedError, "must be logged in")
    end
  end
end
