# frozen_string_literal: true

require "rails_helper"
require "screenshots/driver/cuprite"

RSpec.describe Screenshots::Driver::Cuprite do
  let(:config) do
    Screenshots::Configuration.from_hash(
      "driver" => "cuprite",
      "routes" => [ { "path" => "/", "name" => "home" } ],
      "auth" => {
        "strategy" => "form",
        "login_path" => "/users/sign_in",
        "fields" => {
          "email" => "input[name='user[email]']",
          "password" => "input[name='user[password]']",
          "submit" => "input[name='commit']"
        },
        "credentials" => {
          "email" => "screenshot@example.com",
          "password" => "secret"
        }
      }
    )
  end
  let(:driver) { described_class.new(config:) }
  let(:session) { instance_double(Capybara::Session, current_path: "/dashboard") }

  before do
    allow(Capybara::Session).to receive(:new).and_return(session)
    allow(session).to receive_messages(
      driver: instance_double(Capybara::Cuprite::Driver, quit: true),
      save_screenshot: true,
      visit: true,
      has_no_css?: true,
      find: instance_double(Capybara::Node::Element, set: true, click: true)
    )
  end

  around do |example|
    original_chrome_url = ENV["CHROME_URL"]
    original_app_host = ENV["CAPYBARA_APP_HOST"]
    example.run
  ensure
    ENV["CHROME_URL"] = original_chrome_url
    ENV["CAPYBARA_APP_HOST"] = original_app_host
  end

  it "requires CAPYBARA_APP_HOST when CHROME_URL is configured" do
    ENV["CHROME_URL"] = "ws://localhost:9222"
    ENV.delete("CAPYBARA_APP_HOST")

    expect { driver.send(:setup_capybara) }.to raise_error(RuntimeError, /CAPYBARA_APP_HOST must be set/)
  end

  it "passes base_url to Cuprite when app_host is set" do
    app_host = "http://127.0.0.1:3001"
    cuprite_driver = instance_double(Capybara::Cuprite::Driver)

    allow(Capybara).to receive(:app_host).and_return(app_host)
    allow(Capybara::Cuprite::Driver).to receive(:new).and_return(cuprite_driver)

    driver.send(:register_driver)

    mock_app = instance_double(Rack::Builder)
    Capybara.drivers[driver.send(:driver_name)].call(mock_app)

    expect(Capybara::Cuprite::Driver).to have_received(:new) do |app, **options|
      expect(app).to eq(mock_app)
      expect(options[:base_url]).to eq(app_host)
    end
  end

  it "authenticates with CSS selectors from config" do
    email_field = instance_double(Capybara::Node::Element, set: true)
    password_field = instance_double(Capybara::Node::Element, set: true)
    submit_button = instance_double(Capybara::Node::Element, click: true)
    allow(session).to receive(:find).with("input[name='user[email]']").and_return(email_field)
    allow(session).to receive(:find).with("input[name='user[password]']").and_return(password_field)
    allow(session).to receive(:find).with("input[name='commit']").and_return(submit_button)

    driver.instance_variable_set(:@session, session)
    driver.authenticate(auth_config: config.auth)

    expect(email_field).to have_received(:set).with("screenshot@example.com")
    expect(password_field).to have_received(:set).with("secret")
    expect(submit_button).to have_received(:click)
  end
end
