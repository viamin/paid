# frozen_string_literal: true

require "rails_helper"

RSpec.describe Inbox::OpenInteractiveChat, ".call" do
  self.use_transactional_tests = false

  let(:account) { create(:account) }
  let(:user) { create(:user, :owner, account:) }
  let(:project) { create(:project, account:, created_by: user, auto_pick_enabled: true, active: true) }
  let!(:entry) do
    create(:issue, :needs_input, project:, body: "<!-- paid:enhance-issue -->\n\n## Clarifying questions\n1. What changed?\n")
    Inbox::Queue.call(user:, project:).first
  end

  after do
    ChatSession.where(account:).destroy_all
    account.destroy!
  end

  it "returns the same transcript to simultaneous opens using separate connections" do
    # @spec QUESTION-EXPLORATION-001
    ready = Queue.new
    start = Queue.new

    threads = 2.times.map do
      Thread.new do
        ready << true
        start.pop
        ActiveRecord::Base.connection_pool.with_connection do
          TenantContext.with_system_access do
            described_class.call(user: User.find(user.id), entry:).id
          end
        end
      end
    end
    2.times { ready.pop }
    2.times { start << true }
    threads.each { |thread| raise "Concurrent Inbox open timed out" unless thread.join(10) }

    expect(threads.map(&:value).uniq.size).to eq(1)
    expect(ChatSession.where(created_by: user, inbox_item_key: entry.id).count).to eq(1)
  ensure
    threads&.each { |thread| thread.kill.join if thread.alive? }
  end
end
