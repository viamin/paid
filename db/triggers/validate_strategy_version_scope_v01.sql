CREATE TRIGGER validate_strategy_version_scope
BEFORE INSERT OR UPDATE OF project_id, strategy_version_id ON public.orchestration_decisions
FOR EACH ROW
EXECUTE FUNCTION validate_orchestration_decision_strategy_version_scope();
