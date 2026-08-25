# frozen_string_literal: true

require "rails_helper"

RSpec.describe "RunnerLoginFlows" do
  let(:account) { create(:account) }
  let(:owner_user) { create(:user, :owner, account: account) }

  before { sign_in owner_user }

  it "renders only the registered runner login flows" do
    get new_runner_login_flow_path

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Connect Runner")
    expect(response.body).to include("Claude Browser Login")
    expect(response.body).to include("Connect Codex")
    expect(response.body).to include("Connect Oh My Pi to Claude")
    expect(response.body).to include("Connect OpenCode to Codex")
    expect(response.body).not_to include("Gemini")
    expect(response.body).not_to include("Copilot")
  end
end
