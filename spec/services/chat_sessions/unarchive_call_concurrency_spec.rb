# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChatSessions::Unarchive, ".call" do
  self.use_transactional_tests = false

  let(:account) { create(:account) }
  let(:user) { create(:user, account:) }

  after { account.destroy! }

  # @spec CHAT-API-030
  it "serializes restoring a blank draft with creating a new draft" do
    archived = ChatSessions::Create.call(account:, user:)
    ChatSessions::Archive.call(chat_session: archived)

    results = concurrent_restore_and_create(archived)

    expect(results).to have_attributes(size: 2)
    expect(ChatSession.unstarted_untitled_personal.where(created_by: user)).to contain_exactly(archived.reload)
  end

  private

  def concurrent_restore_and_create(archived)
    ready = Queue.new
    start = Queue.new
    threads = [
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          ready << true
          start.pop
          described_class.call(chat_session: ChatSession.find(archived.id)).id
        end
      end,
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          ready << true
          start.pop
          ChatSessions::Create.call(account: Account.find(account.id), user: User.find(user.id)).id
        end
      end
    ]

    2.times { ready.pop }
    2.times { start << true }
    threads.each { |thread| raise "Concurrent chat lifecycle request timed out" unless thread.join(10) }

    threads.map(&:value)
  ensure
    threads&.each { |thread| thread.kill.join if thread.alive? }
  end
end
