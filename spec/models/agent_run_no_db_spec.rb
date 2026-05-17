# frozen_string_literal: true

require "rails_helper"

RSpec.describe AgentRun, :no_db do
  describe "#effective_prompt" do
    it "remains part of the public model API" do
      expect(described_class.public_instance_methods(false)).to include(:effective_prompt)
      expect(described_class.private_instance_methods(false)).not_to include(:effective_prompt)
    end
  end
end
