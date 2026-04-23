# frozen_string_literal: true

require "rails_helper"

RSpec.describe AbTest, "#complete!" do
  let(:prompt) { create(:prompt, :global, :with_version) }
  let(:variant_version) do
    prompt.create_pending_version!(
      template: "Evolved prompt for {{title}}",
      created_by: "evolution"
    )
  end
  let(:ab_test) do
    test = create(:ab_test, prompt: prompt, status: "draft")
    test.ab_test_variants.create!(prompt_version: prompt.current_version, is_control: true)
    test.ab_test_variants.create!(prompt_version: variant_version, is_control: false)
    test.start!
    test
  end

  it "marks prompt evolution executed from the A/B test start when an evolved variant wins" do
    action = create(:quality_recovery_action, :prompt_evolution, :executing,
      executed_at: nil, result: { ab_test_id: ab_test.id })
    winner = ab_test.non_control_variants.first

    ab_test.complete!(winner: winner)

    action.reload
    expect(action.status).to eq("executed")
    expect(action.executed_at.to_i).to eq(ab_test.started_at.to_i)
    expect(action.result).to include(
      "status" => "winner_found",
      "ab_test_id" => ab_test.id,
      "winner_variant_id" => winner.id
    )
  end

  it "marks prompt evolution failed when no evolved variant wins" do
    action = create(:quality_recovery_action, :prompt_evolution, :executing,
      executed_at: nil, result: { ab_test_id: ab_test.id })

    ab_test.complete!

    expect(action.reload.status).to eq("failed")
    expect(action.result).to include(
      "status" => "no_evolved_winner",
      "ab_test_id" => ab_test.id
    )
  end
end
