CREATE TRIGGER "logidze_on_feature_intent_facet_directions"
BEFORE UPDATE OR INSERT ON "feature_intent_facet_directions" FOR EACH ROW
WHEN (coalesce(current_setting('logidze.disabled', true), '') <> 'on')
EXECUTE PROCEDURE logidze_logger(null, 'updated_at');
