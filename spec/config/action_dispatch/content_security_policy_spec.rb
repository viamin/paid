# frozen_string_literal: true

require "rails_helper"

RSpec.describe ActionDispatch::ContentSecurityPolicy, :no_db do
  it "builds a script nonce into the configured policy and exposes the helper in the layout" do
    policy = Rails.application.config.content_security_policy
    request = ActionDispatch::Request.empty

    request.content_security_policy = policy
    request.content_security_policy_nonce_generator = Rails.application.config.content_security_policy_nonce_generator
    request.content_security_policy_nonce_directives = Rails.application.config.content_security_policy_nonce_directives

    nonce = request.content_security_policy_nonce
    header = policy.build(request, nonce, request.content_security_policy_nonce_directives)
    layout = Rails.root.join("app/views/layouts/application.html.erb").read

    expect(nonce).to be_present
    expect(request.content_security_policy_nonce).to eq(nonce)
    expect(header).to include("script-src 'self' https: 'nonce-#{nonce}'")
    expect(header).to include("object-src 'none'")
    expect(header).to include("style-src 'self' https: 'unsafe-inline'")
    expect(layout).to include(%(<script nonce="<%= content_security_policy_nonce %>">))
  end
end
