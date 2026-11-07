CREATE OR REPLACE FUNCTION public.prevent_intent_checkpoint_terminal_mutation()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
  IF OLD.status IN ('settled', 'rejected') THEN
    RAISE EXCEPTION 'intent_checkpoints terminal settlements are append-only; UPDATE and DELETE are rejected at the database layer (PROJECT-DELEGATION-002)';
  END IF;
  RETURN COALESCE(NEW, OLD);
END;
$function$
