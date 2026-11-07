CREATE OR REPLACE FUNCTION public.prevent_delegation_intent_settlement_mutation()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
  RAISE EXCEPTION 'delegation_intent_settlements is append-only; UPDATE and DELETE are rejected at the database layer (PROJECT-DELEGATION-002)';
END;
$function$
