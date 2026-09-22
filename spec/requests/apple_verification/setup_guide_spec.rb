# frozen_string_literal: true

require "rails_helper"

# Documentation contract for the canonical Apple worker operator guide
# (APPLE-SETUP-006). The guide is a checked-in Markdown file that the
# setup preflight and report both link to; the assertions here pin the
# topics it must cover and the explicit promises it must make so the
# guide cannot silently lose a required section or soften a security
# boundary as it evolves. The guide is consumed as static content
# (linked from the report, copied into operator runbooks), so the
# "request" under test is the read of the canonical file at the
# canonical path — not an HTTP endpoint.
# @spec APPLE-SETUP-006
RSpec.describe "Apple worker operator guide contract" do
  let(:guide_path) { Rails.root.join("docs/rdrs/apple-worker-operator-guide.md") }
  let(:guide_body) { guide_path.read }

  it "exists at the canonical path used by the setup report and plan" do
    expect(guide_path).to exist
  end

  it "is the only Markdown operator guide for the Apple worker setup capability" do
    other_guides = Dir.glob(Rails.root.join("docs/rdrs/apple-worker-*.md")).map { |path| File.basename(path) }
    expect(other_guides).to eq([ "apple-worker-operator-guide.md" ])
  end

  it "covers initial install, profile updates, deprecation/revocation, quarantine, recovery, cleanup, and troubleshooting" do
    expect(guide_body).to include('## 1. Grant virtualization permission')
    expect(guide_body).to include('## 2. Install Tart and Softnet')
    expect(guide_body).to include('## 8. Publish the immutable worker profile')
    expect(guide_body).to include('Profile updates')
    expect(guide_body).to match(/Deprecation\s*\/\s*revocation/i)
    expect(guide_body).to include('Quarantine and return-to-service')
    expect(guide_body).to match(/\bRecovery\b/)
    expect(guide_body).to match(/\bCleanup\b/)
    expect(guide_body).to match(/^## Troubleshooting/m)
  end

  it "states explicitly that routine project use, workflow approval, and verification require no guest login" do
    expect(guide_body).to match(/do\s+not require a guest login/)
    expect(guide_body).to match(/routine project (use|configuration).*approval/i)
  end

  it "states explicitly that the first-release setup requires no Apple ID" do
    expect(guide_body).to match(/first-release setup.*does not require an Apple ID/mi)
  end

  it "declares itself the only Markdown operator guide so no PDF or duplicate guide is introduced" do
    expect(guide_body).to match(/only\*?\* Markdown operator guide/i)
    expect(guide_body).to match(/no PDF or\s+independently maintained duplicate/)
  end
end
