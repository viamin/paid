# frozen_string_literal: true

require "rails_helper"

RSpec.describe Avo::BaseResource, :no_db do
  it "is available for application resources" do
    expect(described_class).to be < Avo::Resources::Base
    expect(Avo::Resources::Account).to be < described_class
    expect(Avo::Resources::User).to be < described_class
  end
end
