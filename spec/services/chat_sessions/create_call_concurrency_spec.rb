# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChatSessions::Create, ".call" do
  self.use_transactional_tests = false

  let(:account) { create(:account) }
  let(:user) { create(:user, account:) }

  after { account.destroy! }

  # @spec CHAT-API-030
  it "returns one personal draft when simultaneous callers create a chat" do
    ready = Queue.new
    start = Queue.new
    threads = 2.times.map do
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          ready << true
          start.pop
          described_class.call(account: Account.find(account.id), user: User.find(user.id)).id
        end
      end
    end

    2.times { ready.pop }
    2.times { start << true }
    threads.each { |thread| raise "Concurrent chat creation timed out" unless thread.join(10) }

    expect(threads.map(&:value).uniq).to have_attributes(size: 1)
    expect(ChatSession.unstarted_untitled_personal.where(created_by: user)).to have_attributes(size: 1)
  ensure
    threads&.each { |thread| thread.kill.join if thread.alive? }
  end
end
