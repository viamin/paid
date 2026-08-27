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

  it "preserves a safe return_to path in flow links" do
    get new_runner_login_flow_path(return_to: "/runners?tab=subscription")

    document = Nokogiri::HTML.parse(response.body)
    hrefs = document.css("a").map { |link| link["href"] }

    expect(response).to have_http_status(:ok)
    expect(hrefs).to include(new_claude_login_session_path(return_to: "/runners?tab=subscription", target_runner_key: "claude"))
    expect(hrefs).to include(new_codex_login_session_path(return_to: "/runners?tab=subscription", target_runner_key: "codex"))
  end

  it "drops an unsafe absolute return_to from flow links" do
    get new_runner_login_flow_path(return_to: "https://evil.example/phish")

    document = Nokogiri::HTML.parse(response.body)
    hrefs = document.css("a").map { |link| link["href"] }

    expect(response).to have_http_status(:ok)
    expect(hrefs).to include(new_claude_login_session_path(target_runner_key: "claude"))
    expect(hrefs).to include(new_codex_login_session_path(target_runner_key: "codex"))
    expect(hrefs.grep(/return_to=/)).to be_empty
  end
end
