# frozen_string_literal: true

require "rails_helper"

RSpec.describe MarketplaceEntryRule, :no_db do
  it "enforces mode uniqueness per marketplace entry" do
    validator = described_class.validators_on(:mode).grep(ActiveRecord::Validations::UniquenessValidator).first

    expect(validator).to be_present
    expect(validator.options[:scope]).to eq(:marketplace_entry_id)
  end
end
