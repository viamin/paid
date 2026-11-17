# frozen_string_literal: true

require "rails_helper"

RSpec.describe FeatureIntents::RespondToDecision do
  self.use_transactional_tests = false

  # Each request locks only its own decision, so the final two answers of a
  # checkpoint can both resolve before either transaction commits. An
  # unlocked completion check would then observe the other answer as still
  # open and both requests would skip settlement, stranding the checkpoint.
  # The check must serialize on the checkpoint so exactly one request
  # finalizes the settlement.
  # @spec PROJECT-DELEGATION-002
  it "settles the checkpoint exactly once when the final two answers race" do
    feature_intent = create(:feature_intent)
    first = create(:feature_intent_decision, feature_intent:)
    second = create(:feature_intent_decision, feature_intent:)
    checkpoint = create(:project_delegation_intent_checkpoint, feature_intent:)
    checkpoint.questions = [ first, second ]
    actor = create(:user, account: feature_intent.project.account)
    account_id = feature_intent.project.account_id

    concurrent_answers({ first.id => "Narrow rollout.", second.id => "Existing records only." }, actor_id: actor.id)

    expect(checkpoint.reload).to be_settled
    expect(checkpoint.settlements.count).to eq(1)
    expect(checkpoint.settlements.sole.answers.values).to contain_exactly("Narrow rollout.", "Existing records only.")
  ensure
    destroy_account(account_id)
  end

  private

  def concurrent_answers(answers, actor_id:)
    resolved = Queue.new
    release = Queue.new
    pause_after_each_resolve(resolved, release)
    threads = answers.map { |decision_id, answer| answer_thread(decision_id, actor_id, answer, resolved, release) }
    2.times { resolved.pop }
    2.times { release << true }
    threads.each do |thread|
      raise "Concurrent checkpoint settlement timed out" unless thread.join(10)

      thread.value
    end
  ensure
    2.times { release << true }
    threads&.each { |thread| thread.kill.join if thread.alive? }
  end

  def answer_thread(decision_id, actor_id, answer, resolved, release)
    Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        TenantContext.with_system_access do
          Thread.current[:hold_before_checkpoint_check] = true
          described_class.call(decision: FeatureIntentDecision.find(decision_id), actor: User.find(actor_id), answer:)
        end
      end
    ensure
      Thread.current[:hold_before_checkpoint_check] = nil
    end
  end

  # The clarity-job enqueue sits between the answer's still-uncommitted UPDATE
  # and the checkpoint completion check, giving the test a deterministic hold
  # point inside the race window.
  def pause_after_each_resolve(resolved, release)
    allow(FeatureIntents::EvaluateCriteriaClarityJob).to receive(:perform_later).and_wrap_original do |original, *args, **kwargs|
      if Thread.current[:hold_before_checkpoint_check]
        resolved << true
        release.pop
      end
      original.call(*args, **kwargs)
    end
  end

  def destroy_account(account_id)
    return if account_id.nil?

    with_committed_connection do
      clear_committed_settlements(account_id)
      # Projects go first so resolved decisions (resolved_by FK to users) are
      # cascaded away before Account's teardown deletes its users.
      Project.where(account_id:).find_each(&:destroy!)
      Account.find(account_id).destroy!
    end
  end

  # Settlements are append-only in production (DB trigger); the committed
  # settlement this spec asserts on must be cleared before the checkpoint
  # cascade can run.
  def clear_committed_settlements(account_id)
    connection = ActiveRecord::Base.connection
    connection.execute("ALTER TABLE project_delegation_intent_settlements DISABLE TRIGGER prevent_project_delegation_intent_settlement_delete")
    begin
      connection.execute(<<~SQL)
        DELETE FROM project_delegation_intent_settlements
        WHERE intent_checkpoint_id IN (
          SELECT checkpoints.id FROM project_delegation_intent_checkpoints checkpoints
          INNER JOIN feature_intents ON feature_intents.id = checkpoints.feature_intent_id
          INNER JOIN projects ON projects.id = feature_intents.project_id
          WHERE projects.account_id = #{connection.quote(account_id)}
        )
      SQL
    ensure
      connection.execute("ALTER TABLE project_delegation_intent_settlements ENABLE TRIGGER prevent_project_delegation_intent_settlement_delete")
    end
  end

  def with_committed_connection(&block)
    Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        TenantContext.with_system_access(&block)
      end
    end.value
  end
end
