# frozen_string_literal: true

require "rails_helper"

RSpec.describe RunnersHelper, :no_db do
  describe "runner auth instruction removal" do
    # @spec RUNNERS-INDEX-006
    it "does not expose the removed auth setup helper API" do
      expect(described_class.const_defined?(:RUNNER_AUTH_INSTRUCTION_COPY, false)).to be(false)
      expect(helper).not_to respond_to(:runner_auth_instruction_blocks)
      expect(helper.private_methods).not_to include(:runner_auth_instruction_block)
    end
  end
end
