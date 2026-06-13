# frozen_string_literal: true

require "rails_helper"

RSpec.describe ModelHealthCheckJob do
  def drift_double(drift: false)
    instance_double(
      Models::DetectCatalogDrift::Result,
      drift?: drift,
      new_model_count: drift ? 2 : 0,
      deprecated_model_count: 0
    )
  end

  def broken_double(broken: false)
    instance_double(Models::DetectBrokenRunnerModels::Result, broken?: broken, findings: broken ? [ {} ] : [])
  end

  before do
    allow(Models::DetectCatalogDrift).to receive(:call).and_return(drift_double)
    allow(Models::DetectBrokenRunnerModels).to receive(:call).and_return(broken_double)
    allow(Models::FileModelHealthIssue).to receive(:call)
  end

  it "does nothing and files no issue when there are no findings" do
    described_class.perform_now

    expect(Models::FileModelHealthIssue).not_to have_received(:call)
  end

  context "when there are findings" do
    let(:account) { create(:account) }

    before do
      create(:project, account: account, owner: "viamin", repo: "paid")
      allow(Models::DetectCatalogDrift).to receive(:call).and_return(drift_double(drift: true))
      allow(Models::DetectBrokenRunnerModels).to receive(:call).and_return(broken_double(broken: true))
      create(:tenant_setting, account: account, self_repo_full_name: "viamin/paid")
      allow(Models::FileModelHealthIssue).to receive(:call)
        .and_return(Models::FileModelHealthIssue::Result.new(action: :created))
    end

    it "files a consolidated issue into the account's self repo" do
      described_class.perform_now

      expect(Models::FileModelHealthIssue).to have_received(:call) do |project:, **|
        expect(project.full_name).to eq("viamin/paid")
      end
    end

    it "skips accounts that have no configured self repo" do
      other = create(:account)
      create(:project, account: other, owner: "someone", repo: "else")

      described_class.perform_now

      expect(Models::FileModelHealthIssue).to have_received(:call).once
    end

    it "runs broken-runner detection inside the account's tenant context (so RLS isolates it)" do
      seen_account = nil
      allow(Models::DetectBrokenRunnerModels).to receive(:call) do
        seen_account = Current.account
        broken_double(broken: true)
      end

      described_class.perform_now

      expect(seen_account).to eq(account)
    end
  end
end
