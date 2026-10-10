# frozen_string_literal: true

require "rails_helper"

RSpec.describe InboxPolicy do
  let(:user) { create(:user) }

  %i[index? count? show? chat?].each do |query|
    describe "##{query}" do
      it "permits a signed-in user" do
        expect(described_class.new(user, :inbox).public_send(query)).to be(true)
      end

      it "denies when there is no user" do
        expect(described_class.new(nil, :inbox).public_send(query)).to be(false)
      end
    end
  end

  describe "Scope" do
    it "resolves for a signed-in user" do
      expect(described_class::Scope.new(user, :inbox).resolve).to eq(:inbox)
    end

    it "raises when there is no user" do
      expect { described_class::Scope.new(nil, :inbox).resolve }.to raise_error(Pundit::NotAuthorizedError)
    end
  end
end
