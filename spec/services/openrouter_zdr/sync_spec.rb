# frozen_string_literal: true

require "rails_helper"

RSpec.describe OpenrouterZdr::Sync do
  let(:payload) { JSON.parse(file_fixture("openrouter_zdr/eligible_endpoints.json").read) }

  before do
    allow(OpenrouterZdr::Client).to receive(:call).and_return(payload.fetch("data"))
  end

  # @spec FREE-MODEL-SYNC-009
  # @spec FREE-MODEL-SYNC-010
  it "maps paid and free endpoint eligibility to concrete runner catalog models" do
    free = create(:llm_model, model_id: "qwen/free-model:free", provider: "qwen",
      pricing_tier: "free", catalog_source: "openrouter_sync")

    described_class.call

    paid = LlmModel.find_by!(model_id: "openai/gpt-paid")

    expect_paid_model(paid)
    expect_preserved_free_model(free)
  end

  # @spec FREE-MODEL-SYNC-011
  it "withdraws eligibility after a successful refresh without deactivating free catalog rows" do
    free = create(:llm_model, model_id: "qwen/free-model:free", provider: "qwen",
      pricing_tier: "free", catalog_source: "openrouter_sync", openrouter_zdr_eligible: true)
    paid = create(:llm_model, model_id: "openai/gpt-paid", provider: "openrouter",
      catalog_source: "openrouter_zdr_sync", openrouter_zdr_eligible: true)
    allow(OpenrouterZdr::Client).to receive(:call).and_return([])

    described_class.call

    aggregate_failures do
      expect(free.reload).to have_attributes(openrouter_zdr_eligible: false, active: true)
      expect(paid.reload).to have_attributes(openrouter_zdr_eligible: false, active: false)
      expect(OpenrouterZdrRefresh.current).to have_attributes(status: "available", last_success_at: be_present)
    end
  end

  # @spec FREE-MODEL-SYNC-012
  it "records a successful empty catalog distinctly from an unavailable refresh" do
    described_class.call
    successful_at = OpenrouterZdrRefresh.current.last_success_at
    allow(OpenrouterZdr::Client).to receive(:call).and_raise(OpenrouterZdr::Client::ParseError, "bad payload")

    expect { described_class.call }.to raise_error(OpenrouterZdr::Client::ParseError)

    expect(OpenrouterZdrRefresh.current).to have_attributes(status: "unavailable", last_success_at: successful_at)
  end

  private

  def expect_paid_model(model)
    aggregate_failures do
      expect(model.reload).to have_attributes(
        provider: "openrouter", catalog_source: "openrouter_zdr_sync", pricing_tier: "paid",
        openrouter_zdr_eligible: true, display_name: "OpenAI: GPT Paid", context_window: 200_000,
        max_output_tokens: 32_000, supports_tools: true
      )
      expect(model.metadata.fetch("openrouter_zdr_endpoints").size).to eq(2)
    end
  end

  def expect_preserved_free_model(model)
    expect(model.reload).to have_attributes(
      catalog_source: "openrouter_sync", pricing_tier: "free", openrouter_zdr_eligible: true
    )
  end
end
