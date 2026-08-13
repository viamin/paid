# frozen_string_literal: true

require "rails_helper"
require "warden/test/helpers"

RSpec.describe "Docker host management", system_driver: :rack_test, type: :system do
  include Warden::Test::Helpers

  let!(:account) { create(:account) }
  let!(:user) { create(:user, :owner, account: account) }
  let!(:tenant_setting) { create(:tenant_setting, account: account) }
  let!(:project) { create(:project, account: account, created_by: user) }
  let!(:docker_host) do
    create(
      :docker_host,
      account: account,
      identifier: "elguapo",
      display_name: "El Guapo",
      daemon_architecture: "arm64",
      daemon_summary: "Docker 28.3",
      failing_check: "proxy_callback",
      manual_concurrency_limit: 3
    )
  end
  let!(:run_on_host) { create(:agent_run, :running, project: project, container_host: "elguapo") }

  before do
    Warden.test_mode!
    login_as(user, scope: :user)
    run_on_host
  end

  after do
    Warden.test_reset!
  end

  it "shows the host index with readiness and capacity details" do
    visit docker_hosts_path

    expect(page).to have_content("Docker Hosts")
    expect(page).to have_content("El Guapo")
    expect(page).to have_content("proxy_callback")
    expect(page).to have_content("Active runs: 1")
    expect(page).to have_content("Available slots: 2")
    expect(page).to have_content("Docker 28.3")
  end

  it "renders the relative proxy callback default in the create form" do
    visit docker_hosts_path

    expect(page).to have_field("Proxy callback URL", with: "/health/services")
  end

  it "updates a host from the edit form" do
    visit edit_docker_host_path(docker_host)

    expect(page).to have_field("Identifier", with: "elguapo", disabled: true)
    fill_in "Display name", with: "Edge Builder"
    fill_in "Manual concurrency limit", with: "6"
    click_button "Save Docker host"

    expect(page).to have_content("Docker host updated.")
    expect(page).to have_content("Edge Builder")
    expect(page).to have_content("Lifecycle")
  end

  it "shows the generic remote Linux setup guide path" do
    visit setup_docker_host_path(docker_host)

    expect(page).to have_content("Remote Docker Setup")
    expect(page).to have_content("Generic remote Linux")
    expect(page).to have_content("Docker TLS connectivity test")
    expect(find_field("Docker save load", type: "textarea").value).to include("docker save paid-agent:latest")
  end

  it "shows QNAP / NAS specific setup guidance" do
    visit setup_docker_host_path(docker_host)

    select "QNAP / NAS", from: "Guide profile"
    click_button "Save setup details"

    expect(page).to have_content("Remote setup details updated.")
    expect(page).to have_content("QNAP Container Station or Docker package UI")
    expect(page).to have_content("QNAP-specific admin UI")
  end

  it "saves placement preferences and shows validation errors" do
    visit docker_hosts_path

    select "El Guapo", from: "Account preferred host"
    click_button "Save account placement"

    expect(page).to have_content("Account Docker host preferences updated.")
    expect(tenant_setting.reload.preferred_docker_host_identifier).to eq("elguapo")

    within("tr##{ActionView::RecordIdentifier.dom_id(project, :placement)}") do
      select "El Guapo", from: "Preferred host"
      click_button "Save"
    end

    expect(page).to have_content("Project Docker host preference updated")
    expect(project.reload.preferred_docker_host_identifier).to eq("elguapo")

    visit docker_hosts_path

    fill_in "Display name", with: "Broken Remote"
    select "Remote", from: "Backend type"
    fill_in "Identifier", with: "broken_remote"
    fill_in "Docker endpoint", with: ""
    fill_in "Proxy callback URL", with: "https://paid.example.test/health/services"
    click_button "Create Docker host"

    expect(page).to have_content("Unable to create Docker host.")
    expect(page).to have_content("Endpoint can't be blank for remote Docker hosts")
  end
end
