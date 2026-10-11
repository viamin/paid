# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20261011044701_add_chat_led_steps_to_onboarding")

RSpec.describe AddChatLedStepsToOnboarding, :aggregate_failures do
  let(:migration) { described_class.new }

  # @spec ONBOARD-CHAT-001
  it "moves an account in the GitHub-token step back to the chat key" do
    account = create(:account)
    create_legacy_steps(account, in_progress: "github_token")

    migration.up

    expect(account.onboarding_steps.ordered.pluck(:step)).to eq(
      %w[account_profile chat_api_key github_token first_project integrations configure_defaults]
    )
    expect(account.onboarding_steps.ordered.pluck(:position)).to eq([ 0, 1, 2, 3, 4, 5 ])
    expect(account.onboarding_steps.find_by!(step: "chat_api_key")).to be_in_progress
    expect(account.onboarding_steps.find_by!(step: "github_token")).to be_pending
  end

  # @spec ONBOARD-CHAT-001
  it "moves an account past the GitHub-token step back to the chat key" do
    account = create(:account)
    create_legacy_steps(account, in_progress: "first_project")

    migration.up

    expect(account.current_onboarding_step).to have_attributes(step: "chat_api_key", position: 1, status: "in_progress")
    expect(account.onboarding_steps.find_by!(step: "github_token")).to be_completed
    expect(account.onboarding_steps.find_by!(step: "first_project")).to be_pending
    expect(account.onboarding_steps.ordered.pluck(:position)).to eq([ 0, 1, 2, 3, 4, 5 ])
  end

  # @spec ONBOARD-CHAT-001
  it "restores the legacy step order on rollback" do
    account = create(:account)
    create_legacy_steps(account, in_progress: "github_token")

    migration.up
    migration.down

    expect(account.onboarding_steps.ordered.pluck(:step)).to eq(
      %w[account_profile github_token first_project configure_defaults]
    )
    expect(account.onboarding_steps.ordered.pluck(:position)).to eq([ 0, 1, 2, 3 ])
  end

  private

  def create_legacy_steps(account, in_progress:)
    %w[account_profile github_token first_project configure_defaults].each_with_index do |step, position|
      status = step == in_progress ? "in_progress" : completed_status_before(step, in_progress)
      create(:onboarding_step, account:, step:, position:, status:)
    end
  end

  def completed_status_before(step, in_progress)
    legacy_step_order.index(step) < legacy_step_order.index(in_progress) ? "completed" : "pending"
  end

  def legacy_step_order
    %w[account_profile github_token first_project configure_defaults]
  end
end
