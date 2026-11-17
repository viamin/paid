CREATE OR REPLACE FUNCTION public.validate_strategy_version_parent_reference()
RETURNS trigger
LANGUAGE plpgsql
SET search_path TO pg_catalog, public
AS $function$
BEGIN
  IF NEW.parent_version_id IS NOT NULL THEN
    PERFORM id FROM public.strategy_versions
      WHERE id = NEW.parent_version_id AND strategy_id = NEW.strategy_id
      FOR SHARE;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'parent_version_id must belong to the same strategy'
        USING ERRCODE = '23514';
    END IF;
  END IF;

  IF TG_OP = 'UPDATE' THEN
    IF NEW.strategy_id IS DISTINCT FROM OLD.strategy_id AND (
      EXISTS (
        SELECT 1 FROM public.strategies
        WHERE current_version_id = OLD.id AND id <> NEW.strategy_id
      ) OR EXISTS (
        SELECT 1 FROM public.strategy_versions
        WHERE parent_version_id = OLD.id AND strategy_id <> NEW.strategy_id
      )
    ) THEN
      RAISE EXCEPTION 'strategy_id cannot change while another strategy retains version references'
        USING ERRCODE = '23514';
    END IF;
  END IF;

  RETURN NEW;
END;
$function$;
