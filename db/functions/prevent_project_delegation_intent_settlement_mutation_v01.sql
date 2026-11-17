CREATE OR REPLACE FUNCTION public.prevent_project_delegation_intent_settlement_mutation()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  RAISE EXCEPTION 'project_delegation_intent_settlements is append-only; UPDATE and DELETE are rejected (PROJECT-DELEGATION-002)';
END;
$$;
