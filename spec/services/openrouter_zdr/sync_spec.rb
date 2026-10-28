# frozen_string_literal: true

require "rails_helper"

RSpec.describe OpenrouterZdr::Sync do
  let(:payloads) do
    [
      {
        "name" => "Paid Provider | paid/model",
        "model_id" => "paid/model",
        "model_name" => "Paid Model",
        "provider_name" => "Paid Provider",
        "context_length" => 128_000,
        "max_completion_tokens" => 16_000
      },
      {
        "name" => "Free Provider | free/model",
        "model_id" => "free/model",
        "model_name" => "Free Model",
        "provider_name" => "Free Provider",
        "pricing" => { "prompt" => "0", "completion" => "0" }
      }
    ]
  end

  before { allow(OpenrouterZdr::Client).to receive(:call).and_return(payloads) }

  it "maps paid and free endpoint eligibility to concrete model rows" do # @spec OPENROUTER-ZDR-002
    expect { described_class.call }.to change(LlmModel, :count).by(2)

    expect(LlmModel.openrouter_zdr_eligible.pluck(:model_id)).to contain_exactly("paid/model", "free/model")
    expect(LlmModel.find_by!(model_id: "paid/model")).to have_attributes(
      display_name: "Paid Model", provider: "openrouter", catalog_source: "openrouter_zdr_sync"
    )
    expect(OpenrouterZdrSync.current).to have_attributes(status: "available", models_count: 2)
  end

  it "is idempotent and withdraws endpoints absent from a successful refresh" do # @spec OPENROUTER-ZDR-003
    described_class.call
    allow(OpenrouterZdr::Client).to receive(:call).and_return([ payloads.first ])

    expect { described_class.call }.not_to change(LlmModel, :count)
    expect(LlmModel.openrouter_zdr_eligible.pluck(:model_id)).to eq([ "paid/model" ])
    expect(LlmModel.find_by!(model_id: "free/model").active).to be(false)
  end

  it "preserves last-known eligibility and records unavailability on failure" do # @spec OPENROUTER-ZDR-005
    described_class.call
    allow(OpenrouterZdr::Client).to receive(:call).and_raise(OpenrouterZdr::Client::ResponseError, "503")

    result = described_class.call

    expect(result.status).to eq("unavailable")
    expect(OpenrouterZdrSync.current).to have_attributes(status: "unavailable", models_count: 2)
    expect(LlmModel.openrouter_zdr_eligible.pluck(:model_id)).to contain_exactly("paid/model", "free/model")
  end

  it "preserves last-known eligibility when a response is malformed" do # @spec OPENROUTER-ZDR-006
    described_class.call
    allow(OpenrouterZdr::Client).to receive(:call).and_raise(OpenrouterZdr::Client::ParseError, "malformed")

    described_class.call

    expect(OpenrouterZdrSync.current.status).to eq("unavailable")
    expect(LlmModel.openrouter_zdr_eligible.pluck(:model_id)).to contain_exactly("paid/model", "free/model")
  end

  it "replaces a successful empty catalog" do # @spec OPENROUTER-ZDR-004
    described_class.call
    allow(OpenrouterZdr::Client).to receive(:call).and_return([])

    described_class.call

    expect(LlmModel.openrouter_zdr_eligible).to be_empty
    expect(OpenrouterZdrSync.current).to have_attributes(status: "available", models_count: 0)
  end
end
