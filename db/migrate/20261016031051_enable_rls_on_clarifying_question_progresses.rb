# frozen_string_literal: true

class EnableRlsOnClarifyingQuestionProgresses < ActiveRecord::Migration[8.1]
  def up
    safety_assured do
      execute <<~SQL
        ALTER TABLE clarifying_question_progresses ENABLE ROW LEVEL SECURITY;
        ALTER TABLE clarifying_question_progresses FORCE ROW LEVEL SECURITY;
        CREATE POLICY tenant_isolation ON clarifying_question_progresses
          AS PERMISSIVE FOR ALL
          USING (paid_tenant_bypass() OR (clarifying_question_progresses.account_id = paid_current_account_id()))
          WITH CHECK (paid_tenant_bypass() OR (clarifying_question_progresses.account_id = paid_current_account_id()));
      SQL
    end
  end

  def down
    safety_assured do
      execute "DROP POLICY IF EXISTS tenant_isolation ON clarifying_question_progresses"
      execute "ALTER TABLE clarifying_question_progresses NO FORCE ROW LEVEL SECURITY"
      execute "ALTER TABLE clarifying_question_progresses DISABLE ROW LEVEL SECURITY"
    end
  end
end
