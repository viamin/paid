CREATE OR REPLACE FUNCTION public.validate_strategy_current_version_reference()
RETURNS trigger
LANGUAGE plpgsql
SET search_path TO pg_catalog, public
AS $function$
BEGIN
  IF NEW.current_version_id IS NOT NULL THEN
    PERFORM id FROM public.strategy_versions
      WHERE id = NEW.current_version_id AND strategy_id = NEW.id
      FOR SHARE;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'current_version_id must belong to the same strategy'
        USING ERRCODE = '23514';
    END IF;
  END IF;

  RETURN NEW;
END;
$function$;
