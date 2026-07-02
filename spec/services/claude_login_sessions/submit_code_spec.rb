# frozen_string_literal: true

require "rails_helper"

RSpec.describe ClaudeLoginSessions::SubmitCode do
  let(:account) { create(:account) }
  let(:owner_user) { create(:user, :owner, account: account) }
  let(:session_record) do
    create(
      :claude_login_session,
      account: account,
      created_by: owner_user,
      status: "awaiting_code"
    )
  end
  let(:coordination) { instance_double(ClaudeLoginSessions::Coordination) }

  before do
    allow(ClaudeLoginSessions::Coordination).to receive(:new)
      .with(session: have_attributes(id: session_record.id))
      .and_return(coordination)
  end

  it "enqueues the browser code through shared coordination" do
    allow(coordination).to receive(:live?).and_return(true)
    allow(coordination).to receive(:enqueue_code)

    result = described_class.call(
      session: session_record,
      session_token: session_record.session_token,
      code: "code-123"
    )

    expect(result.success?).to be(true)
    expect(coordination).to have_received(:enqueue_code).with("code-123")
    expect(session_record.reload.status).to eq("authorizing")
    expect(session_record.submitted_at).to be_present
  end

  it "fails when the live process is no longer reachable" do
    allow(coordination).to receive(:live?).and_return(false)
    allow(coordination).to receive(:enqueue_code)

    result = described_class.call(
      session: session_record,
      session_token: session_record.session_token,
      code: "code-123"
    )

    expect(result.success?).to be(false)
    expect(result.error_message).to eq("The live Claude login process is no longer available. Start a new browser login.")
    expect(coordination).not_to have_received(:enqueue_code)
    expect(session_record.reload.status).to eq("failed")
  end

  it "rejects duplicate submissions after the session starts authorizing" do
    session_record.update!(status: "authorizing")
    allow(coordination).to receive(:live?).and_return(true)
    allow(coordination).to receive(:enqueue_code)

    result = described_class.call(
      session: session_record,
      session_token: session_record.session_token,
      code: "code-123"
    )

    expect(result.success?).to be(false)
    expect(result.error_message).to eq("This Claude login session is no longer accepting codes.")
    expect(coordination).not_to have_received(:enqueue_code)
    expect(session_record.reload.status).to eq("authorizing")
  end

  it "rejects a stale retry after another request already moved the session forward" do
    stale_session = ClaudeLoginSession.find(session_record.id)
    allow(coordination).to receive(:live?).and_return(true)
    allow(coordination).to receive(:enqueue_code)

    first_result = described_class.call(
      session: session_record,
      session_token: session_record.session_token,
      code: "code-123"
    )
    second_result = described_class.call(
      session: stale_session,
      session_token: stale_session.session_token,
      code: "code-456"
    )

    expect(first_result.success?).to be(true)
    expect(second_result.success?).to be(false)
    expect(second_result.error_message).to eq("This Claude login session is no longer accepting codes.")
    expect(coordination).to have_received(:enqueue_code).once.with("code-123")
    expect(session_record.reload.status).to eq("authorizing")
  end
end
