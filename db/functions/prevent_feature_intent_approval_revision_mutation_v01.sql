CREATE OR REPLACE FUNCTION public.prevent_feature_intent_approval_revision_mutation()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
  RAISE EXCEPTION 'feature_intent_approval_revisions is append-only; UPDATE and DELETE are rejected at the database layer (FEATURE-APPROVAL-014)';
END;
$function$