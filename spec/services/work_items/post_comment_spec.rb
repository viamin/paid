# frozen_string_literal: true

require "rails_helper"

RSpec.describe WorkItems::PostComment do
  let(:account) { create(:account) }
  let(:project) { create(:project, account:) }
  let(:configuration) { create(:tracker_configuration, configurable: account, tracker_type: "linear") }
  let(:work_item) { create(:work_item, account:, tracker_configuration: configuration) }
  let(:adapter) { instance_double(IssueTrackers::Adapters::Base) }

  before do
    account.tenant_setting!.update!(features: { "unified_work_items" => true })
    allow(configuration).to receive(:adapter).and_return(adapter)
  end

  it "posts through the tracker adapter as the configured API-key user when permitted" do
    # @spec UNIFIED-WORK-ITEMS-005
    allow(adapter).to receive(:add_comment).with(external_id: work_item.external_id, body: "Paid opened PR #1")

    result = described_class.call(work_item:, project:, body: "Paid opened PR #1")

    expect(result).to eq(:posted)
  end

  it "suppresses the comment under project quiet mode" do
    project.update!(quiet_mode: true)

    result = described_class.call(work_item:, project:, body: "Quiet please")

    expect(result).to eq(:suppressed)
  end

  it "returns rollout_disabled while the guard is off" do
    # @spec UNIFIED-WORK-ITEMS-009
    account.tenant_setting!.update!(features: { "unified_work_items" => false })

    result = described_class.call(work_item:, project:, body: "Hidden")

    expect(result).to eq(:rollout_disabled)
  end

  it "returns unsupported without a tracker configuration" do
    work_item.update!(tracker_configuration: nil)

    result = described_class.call(work_item:, project:, body: "Nowhere to post")

    expect(result).to eq(:unsupported)
  end

  it "reports a provider failure without raising" do
    allow(adapter).to receive(:add_comment).and_raise(IssueTrackers::Adapters::Linear::ResponseError, "boom")

    result = described_class.call(work_item:, project:, body: "Failing post")

    expect(result).to eq(:failed)
  end
end
