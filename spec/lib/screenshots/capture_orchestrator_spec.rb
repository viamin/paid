# frozen_string_literal: true

require "rails_helper"
require "screenshots/capture_orchestrator"

RSpec.describe Screenshots::CaptureOrchestrator do
  let(:output_dir) { Dir.mktmpdir }
  let(:driver) do
    instance_double(
      Screenshots::Driver::Cuprite,
      start_browser: true,
      visit: true,
      wait_for_load: true,
      screenshot: true,
      authenticate: true,
      quit: true,
      current_path: "/projects/1"
    )
  end
  let(:events) { [] }
  let(:setup_runner) { instance_double(Screenshots::SetupRunner, call: true) }
  let(:seed_runner) { instance_double(Screenshots::SeedRunner, call: seed_data) }
  let(:seed_data) { { project: OpenStruct.new(id: 1), user: OpenStruct.new(email: "screenshot@example.com", password: "secret") } }
  let(:config) do
    Screenshots::Configuration.from_hash(
      "driver" => "cuprite",
      "routes" => [
        { "path" => "/users/sign_in", "name" => "sign_in" },
        { "path" => "/projects/:project_id", "name" => "project_show", "requires_auth" => true, "seed_key" => "project" }
      ],
      "auth" => {
        "strategy" => "form",
        "login_path" => "/users/sign_in",
        "fields" => {
          "email" => "input[name='user[email]']",
          "password" => "input[name='user[password]']",
          "submit" => "input[name='commit']"
        },
        "credentials" => {
          "email" => "%{user_email}",
          "password" => "%{user_password}"
        }
      },
      "setup_commands" => [ "bin/rails db:prepare" ]
    )
  end

  after do
    FileUtils.rm_rf(output_dir)
  end

  def build_orchestrator(config:, targets: nil, seed_runner_double: seed_runner)
    described_class.new(
      output_dir: output_dir,
      repo_path: Rails.root.to_s,
      project: nil,
      config: config,
      targets: targets
    ).tap do |orchestrator|
      allow(orchestrator).to receive_messages(
        setup_runner: setup_runner,
        seed_runner: seed_runner_double
      )
    end
  end

  it "captures unauthenticated routes before authenticating and returns screenshot paths" do
    allow(Screenshots::Driver::Cuprite).to receive(:new).and_return(driver)
    allow(driver).to receive(:visit) { |path| events << [ :visit, path ] }
    allow(driver).to receive(:authenticate) { events << [ :authenticate ] }

    orchestrator = build_orchestrator(config:)

    result = orchestrator.call

    expect(setup_runner).to have_received(:call).with(commands: [ "bin/rails db:prepare" ], repo_path: Rails.root.to_s)
    expect(events).to eq([
      [ :visit, "/users/sign_in" ],
      [ :authenticate ],
      [ :visit, "/projects/1" ]
    ])
    expect(result.paths).to eq(
      [
        "#{output_dir}/sign_in.png",
        "#{output_dir}/project_show.png"
      ]
    )
  end

  it "selects the configured Playwright driver" do
    playwright_config = Screenshots::Configuration.from_hash(
      "driver" => "playwright",
      "routes" => [ { "path" => "/", "name" => "home" } ]
    )
    playwright_driver = instance_double(
      Screenshots::Driver::Playwright,
      start_browser: true,
      visit: true,
      wait_for_load: true,
      screenshot: true,
      quit: true,
      current_path: "/"
    )
    allow(Screenshots::Driver::Playwright).to receive(:new).and_return(playwright_driver)

    orchestrator = build_orchestrator(
      config: playwright_config,
      seed_runner_double: instance_double(Screenshots::SeedRunner, call: {})
    )

    orchestrator.call

    expect(Screenshots::Driver::Playwright).to have_received(:new).with(config: playwright_config, repo_path: Rails.root.to_s)
  end

  it "fails fast when authenticated routes are configured without an auth strategy" do
    unauthenticated_config = Screenshots::Configuration.from_hash(
      "driver" => "cuprite",
      "routes" => [
        { "path" => "/", "name" => "home" },
        { "path" => "/projects/:project_id", "name" => "project_show", "requires_auth" => true, "seed_key" => "project" }
      ]
    )

    orchestrator = build_orchestrator(config: unauthenticated_config)

    expect { orchestrator.call }
      .to raise_error(ArgumentError, /authenticated routes.*auth\.strategy is missing or none/)
    expect(driver).not_to have_received(:start_browser)
  end

  it "can capture legacy target objects passed by the compatibility wrapper" do
    target = Screenshots::CaptureTargets::Target.new(
      slug: "project_show",
      path_builder: ->(records) { "/projects/#{records.fetch(:project).id}" },
      requires_auth: true
    )
    allow(Screenshots::Driver::Cuprite).to receive(:new).and_return(driver)

    orchestrator = build_orchestrator(config:, targets: [ target ])

    result = orchestrator.call

    expect(driver).to have_received(:visit).with("/projects/1")
    expect(result.paths).to eq([ "#{output_dir}/project_show.png" ])
  end
end
