# frozen_string_literal: true

require "rails_helper"

# @spec APPLE-WORKER-008
# @spec APPLE-WORKER-009
RSpec.describe AppleVerification::HostService do
  let(:provider) { instance_double(AppleVerification::TartProvider) }
  let(:service) do
    described_class.new(provider:, token: "host-token", approved_images: [ "paid-macos-26.0" ])
  end

  it "authenticates and dispatches only the versioned lifecycle vocabulary" do
    allow(provider).to receive(:readiness).and_return({ "cpu" => { "available_cores" => 4 } })

    result = service.call(version: "v1", operation: "readiness", payload: {}, token: "host-token")

    expect(result).to include("cpu" => { "available_cores" => 4 })
    expect { service.call(version: "v2", operation: "exec", payload: {}, token: "host-token") }
      .to raise_error(AppleVerification::HostService::UnsupportedRequestError)
    expect { service.call(version: "v1", operation: "readiness", payload: {}, token: "wrong") }
      .to raise_error(AppleVerification::HostService::AuthenticationError)
  end

  it "rejects executable text, paths, mounts, and unapproved images before provider work" do
    allow(provider).to receive(:clone)
    bad_payloads = [
      { "command" => "rm -rf /" },
      { "repository_path" => "/workspace/customer" },
      { "host_mounts" => [ "/Users/operator" ] },
      { "image_id" => "unapproved-image" }
    ]

    bad_payloads.each do |payload|
      expect {
        service.call(version: "v1", operation: "clone", payload:, token: "host-token")
      }.to raise_error(AppleVerification::HostService::UnsafeRequestError)
    end

    expect(provider).not_to have_received(:clone)
  end

  it "passes approved clone fields with reconciliation ownership to the provider" do
    allow(provider).to receive(:clone).and_return({ "vm_id" => "paid-vm-1" })
    ownership_tags = reconciliation_ownership_tags

    result = service.call(
      version: "v1", operation: "clone",
      payload: { "request_id" => "request-1", "image_id" => "paid-macos-26.0", "ownership_tags" => ownership_tags },
      token: "host-token"
    )

    expect(result).to eq("vm_id" => "paid-vm-1")
    expect(provider).to have_received(:clone).with(
      request_id: "request-1", image_id: "paid-macos-26.0", ownership_tags: ownership_tags
    )
  end

  it "rejects clone ownership tags outside the Paid reconciliation boundary" do
    allow(provider).to receive(:clone)

    expect {
      service.call(
        version: "v1", operation: "clone",
        payload: { "request_id" => "request-1", "image_id" => "paid-macos-26.0", "ownership_tags" => { "paid.run_id" => "7" } },
        token: "host-token"
      )
    }.to raise_error(AppleVerification::HostService::UnsafeRequestError, "Host clone must use the Paid reconciliation tag set")

    expect(provider).not_to have_received(:clone)
  end

  it "limits inventory to the Paid reconciliation tag set" do
    allow(provider).to receive(:inventory).and_return([])
    reconciliation_tags = reconciliation_ownership_tags.transform_values { nil }

    result = service.call(
      version: "v1", operation: "inventory",
      payload: { "ownership_tags" => reconciliation_tags }, token: "host-token"
    )

    expect(result).to eq([])
    expect(provider).to have_received(:inventory).with(ownership_tags: reconciliation_tags)
  end

  it "rejects inventory filters outside the Paid reconciliation boundary" do
    allow(provider).to receive(:inventory)
    invalid_filters = [ {}, { "owner" => "other-workload" }, { "paid.run_id" => "7" } ]

    invalid_filters.each do |ownership_tags|
      expect {
        service.call(
          version: "v1", operation: "inventory",
          payload: { "ownership_tags" => ownership_tags }, token: "host-token"
        )
      }.to raise_error(AppleVerification::HostService::UnsafeRequestError)
    end

    expect(provider).not_to have_received(:inventory)
  end

  def reconciliation_ownership_tags
    {
      "paid.account_id" => "1",
      "paid.project_id" => "2",
      "paid.run_id" => "7",
      "paid.created_at" => "2026-09-20T00:00:00Z"
    }
  end
end
