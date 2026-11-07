# frozen_string_literal: true

require "rails_helper"

RSpec.describe ApplicationHelper, :no_db do
  # @spec PARTIAL-CLOSEOUT-044
  it "renders waiting recovery distinctly from queued work" do
    badge = helper.agent_run_status_badge("waiting_recovery")

    expect(badge).to include("Waiting Recovery")
    expect(badge).to include("bg-amber-100")
  end
end
