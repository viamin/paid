# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Partial closeout operator guide" do # @spec PARTIAL-CLOSEOUT-022
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }

  it "requires authentication" do
    get partial_closeout_guide_path

    expect(response).to redirect_to(new_user_session_path)
  end

  it "explains run completion and evidence-gated GitHub closure separately" do # @spec PARTIAL-CLOSEOUT-037
    sign_in user

    get partial_closeout_guide_path

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Partial closeout operator guide")
    expect(response.body).to include("completes a run")
    expect(response.body).to include("What clears an Inbox item")
    expect(response.body).to include("Close on GitHub")
    expect(response.body).to include("never hidden merely")
  end

  it "distinguishes audit completion, gap transfer, and epic acceptance" do
    sign_in user

    get partial_closeout_guide_path

    expect(response.body).to include("A follow-up owner is not completed acceptance evidence")
    expect(response.body).to include("preserves ownership of the outstanding requirement")
    expect(response.body).to include("explicitly authorized scope revision")
  end

  it "explains continuation authorization semantics with examples" do
    sign_in user

    get partial_closeout_guide_path

    expect(response.body).to include("authorizes exactly one run")
    expect(response.body).to include("Other holds still apply")
    expect(response.body).to include("acceptance audit")
    expect(response.body).to include("implementation gap")
    expect(response.body).to include("scanner verification")
    expect(response.body).to include("human-only evaluation")
  end

  it "explains human evidence handling and automatic versus deliberate resumption" do
    sign_in user

    get partial_closeout_guide_path

    expect(response.body).to include("who must supply it")
    expect(response.body).to include("resumes automatically")
    expect(response.body).to include("deliberate continuation")
    expect(response.body).to include("never retries an agent for unavailable human evidence")
  end
end
