# frozen_string_literal: true

require "rails_helper"

RSpec.describe Automation::Providers::Data::CheckRun do
  it "is an immutable Data class with the documented fields" do
    cr = described_class.new(name: "rspec", status: :completed, conclusion: :success, url: nil)
    expect(cr.status).to eq(:completed)
    expect(cr.conclusion).to eq(:success)
  end

  it "declares the provider-neutral status and conclusion enums" do
    expect(described_class::STATUSES).to include(:queued, :in_progress, :completed)
    expect(described_class::CONCLUSIONS).to include(:success, :failure, :cancelled, :timed_out)
  end
end
