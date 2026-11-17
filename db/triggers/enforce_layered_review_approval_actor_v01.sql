CREATE TRIGGER enforce_layered_review_approval_actor
BEFORE INSERT OR UPDATE OF package_id, approved_by_id ON public.layered_verification_review_approvals
FOR EACH ROW EXECUTE FUNCTION public.enforce_layered_review_approval_actor();
