# frozen_string_literal: true

require "rails_helper"

RSpec.describe PromptPolicy do
  describe "permissions" do
    describe "#index?" do
      it "permits any authenticated user" do
        account = create(:account)
        user = create(:user, account: account)
        prompt = create(:prompt, :for_account, account: account)

        expect(described_class.new(user, prompt)).to be_index
      end

      it "does not permit nil user" do
        prompt = create(:prompt, :global)

        expect(described_class.new(nil, prompt)).not_to be_index
      end
    end

    describe "#show?" do
      it "permits viewing global prompts" do
        account = create(:account)
        user = create(:user, account: account)
        prompt = create(:prompt, :global)

        expect(described_class.new(user, prompt)).to be_show
      end

      it "permits viewing account prompts for same account" do
        account = create(:account)
        user = create(:user, account: account)
        prompt = create(:prompt, :for_account, account: account)

        expect(described_class.new(user, prompt)).to be_show
      end

      it "does not permit viewing other account prompts" do
        account = create(:account)
        user = create(:user, account: account)
        other_account = create(:account)
        prompt = create(:prompt, :for_account, account: other_account)

        expect(described_class.new(user, prompt)).not_to be_show
      end

      it "does not permit nil user to view global prompts" do
        prompt = create(:prompt, :global)

        expect(described_class.new(nil, prompt)).not_to be_show
      end
    end

    describe "#create?" do
      it "permits owner" do
        account = create(:account)
        owner = create(:user, account: account)
        prompt = build(:prompt, account: account)

        expect(described_class.new(owner, prompt)).to be_create
      end

      it "permits admin" do
        account = create(:account)
        create(:user, account: account) # absorb owner role
        admin = create(:user, :admin, account: account)
        prompt = build(:prompt, account: account)

        expect(described_class.new(admin, prompt)).to be_create
      end

      it "does not permit member" do
        account = create(:account)
        create(:user, account: account) # absorb owner role
        member = create(:user, :member, account: account)
        prompt = build(:prompt, account: account)

        expect(described_class.new(member, prompt)).not_to be_create
      end

      it "does not permit creating global prompts" do
        account = create(:account)
        owner = create(:user, account: account)
        prompt = build(:prompt, :global)

        expect(described_class.new(owner, prompt)).not_to be_create
      end
    end

    describe "#update?" do
      it "permits owner for account prompt" do
        account = create(:account)
        owner = create(:user, account: account)
        prompt = create(:prompt, :for_account, account: account)

        expect(described_class.new(owner, prompt)).to be_update
      end

      it "permits admin for account prompt" do
        account = create(:account)
        create(:user, account: account) # absorb owner role
        admin = create(:user, :admin, account: account)
        prompt = create(:prompt, :for_account, account: account)

        expect(described_class.new(admin, prompt)).to be_update
      end

      it "does not permit member" do
        account = create(:account)
        create(:user, account: account) # absorb owner role
        member = create(:user, :member, account: account)
        prompt = create(:prompt, :for_account, account: account)

        expect(described_class.new(member, prompt)).not_to be_update
      end

      it "does not permit updating other account's prompts" do
        account = create(:account)
        user = create(:user, account: account)
        other_account = create(:account)
        prompt = create(:prompt, :for_account, account: other_account)

        expect(described_class.new(user, prompt)).not_to be_update
      end

      it "does not permit updating global prompts" do
        account = create(:account)
        owner = create(:user, account: account)
        prompt = create(:prompt, :global)

        expect(described_class.new(owner, prompt)).not_to be_update
      end
    end

    describe "#destroy?" do
      it "permits owner for account prompt" do
        account = create(:account)
        owner = create(:user, account: account)
        prompt = create(:prompt, :for_account, account: account)

        expect(described_class.new(owner, prompt)).to be_destroy
      end

      it "does not permit destroying global prompts" do
        account = create(:account)
        owner = create(:user, account: account)
        prompt = create(:prompt, :global)

        expect(described_class.new(owner, prompt)).not_to be_destroy
      end

      it "does not permit admin to destroy" do
        account = create(:account)
        create(:user, account: account) # absorb owner role
        admin = create(:user, :admin, account: account)
        prompt = create(:prompt, :for_account, account: account)

        expect(described_class.new(admin, prompt)).not_to be_destroy
      end
    end

    describe "#diff?" do
      it "permits viewing diff for global prompts" do
        account = create(:account)
        user = create(:user, account: account)
        prompt = create(:prompt, :global)

        expect(described_class.new(user, prompt)).to be_diff
      end

      it "permits viewing diff for account prompts" do
        account = create(:account)
        user = create(:user, account: account)
        prompt = create(:prompt, :for_account, account: account)

        expect(described_class.new(user, prompt)).to be_diff
      end
    end
  end

  describe "Scope" do
    it "returns global prompts and account prompts" do
      account = create(:account)
      user = create(:user, account: account)
      global_prompt = create(:prompt, :global)
      account_prompt = create(:prompt, :for_account, account: account)
      other_account = create(:account)
      other_prompt = create(:prompt, :for_account, account: other_account)

      scope = described_class::Scope.new(user, Prompt).resolve

      expect(scope).to include(global_prompt)
      expect(scope).to include(account_prompt)
      expect(scope).not_to include(other_prompt)
    end

    it "raises error when user is not logged in" do
      expect {
        described_class::Scope.new(nil, Prompt).resolve
      }.to raise_error(Pundit::NotAuthorizedError, "must be logged in")
    end
  end
end
