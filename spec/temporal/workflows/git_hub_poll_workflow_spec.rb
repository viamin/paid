# frozen_string_literal: true

require "rails_helper"

RSpec.describe Workflows::GitHubPollWorkflow do
  let(:workflow) { described_class.new }

  describe "#execute" do
    it "is defined as a Temporal workflow" do
      expect(described_class).to be < Workflows::BaseWorkflow
    end

    it "inherits from BaseWorkflow" do
      expect(described_class.superclass).to eq(Workflows::BaseWorkflow)
    end
  end
end
