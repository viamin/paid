# frozen_string_literal: true

require "rails_helper"

RSpec.describe Avo::Resources::AccountActivityEvent, :no_db do
  # @spec PROJECT-DELEGATION-001
  it "exposes every audit event field as read-only" do
    fields = described_class.new(view: :show).detect_fields.get_field_definitions

    expect(fields).to all(have_attributes(readonly: true))
  end
end
