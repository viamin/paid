CREATE TRIGGER validate_strategy_current_version_reference
BEFORE INSERT OR UPDATE OF current_version_id, id ON public.strategies
FOR EACH ROW
EXECUTE FUNCTION public.validate_strategy_current_version_reference();
