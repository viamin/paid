SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: pg_trgm; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS pg_trgm WITH SCHEMA public;


--
-- Name: EXTENSION pg_trgm; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON EXTENSION pg_trgm IS 'text similarity measurement and index searching based on trigrams';


--
-- Name: paid_current_account_id(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.paid_current_account_id() RETURNS bigint
    LANGUAGE sql STABLE
    AS $$
  SELECT NULLIF(current_setting('paid.current_account_id', true), '')::bigint
$$;


--
-- Name: paid_tenant_bypass(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.paid_tenant_bypass() RETURNS boolean
    LANGUAGE sql STABLE
    AS $$
  SELECT current_setting('paid.bypass_tenant_rls', true) = 'true'
$$;


SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: ab_test_assignments; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.ab_test_assignments (
    id bigint NOT NULL,
    ab_test_id bigint NOT NULL,
    ab_test_variant_id bigint NOT NULL,
    agent_run_id bigint NOT NULL,
    quality_score numeric(5,4),
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);

ALTER TABLE ONLY public.ab_test_assignments FORCE ROW LEVEL SECURITY;


--
-- Name: ab_test_assignments_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.ab_test_assignments_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: ab_test_assignments_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.ab_test_assignments_id_seq OWNED BY public.ab_test_assignments.id;


--
-- Name: ab_test_variants; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.ab_test_variants (
    id bigint NOT NULL,
    ab_test_id bigint NOT NULL,
    prompt_version_id bigint NOT NULL,
    is_control boolean DEFAULT false NOT NULL,
    sample_count integer DEFAULT 0 NOT NULL,
    total_quality_score numeric(10,4) DEFAULT 0.0 NOT NULL,
    avg_quality_score numeric(5,4),
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);

ALTER TABLE ONLY public.ab_test_variants FORCE ROW LEVEL SECURITY;


--
-- Name: ab_test_variants_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.ab_test_variants_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: ab_test_variants_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.ab_test_variants_id_seq OWNED BY public.ab_test_variants.id;


--
-- Name: ab_tests; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.ab_tests (
    id bigint NOT NULL,
    prompt_id bigint NOT NULL,
    name character varying(255) NOT NULL,
    description text,
    status character varying(50) DEFAULT 'draft'::character varying NOT NULL,
    control_version_id bigint NOT NULL,
    winner_variant_id bigint,
    min_samples_per_variant integer DEFAULT 30 NOT NULL,
    confidence_threshold numeric(5,4) DEFAULT 0.95 NOT NULL,
    started_at timestamp(6) without time zone,
    completed_at timestamp(6) without time zone,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    cached_analysis jsonb,
    analysis_samples_key character varying
);

ALTER TABLE ONLY public.ab_tests FORCE ROW LEVEL SECURITY;


--
-- Name: ab_tests_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.ab_tests_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: ab_tests_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.ab_tests_id_seq OWNED BY public.ab_tests.id;


--
-- Name: account_memberships; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.account_memberships (
    id bigint NOT NULL,
    user_id bigint NOT NULL,
    account_id bigint NOT NULL,
    role integer DEFAULT 0 NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);

ALTER TABLE ONLY public.account_memberships FORCE ROW LEVEL SECURITY;


--
-- Name: account_memberships_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.account_memberships_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: account_memberships_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.account_memberships_id_seq OWNED BY public.account_memberships.id;


--
-- Name: accounts; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.accounts (
    id bigint NOT NULL,
    name character varying NOT NULL,
    slug character varying NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    default_max_tokens_per_run integer DEFAULT 10000000 NOT NULL,
    scheduler_paused_at timestamp(6) without time zone,
    status integer DEFAULT 0 NOT NULL,
    suspended_at timestamp(6) without time zone,
    deactivated_at timestamp(6) without time zone,
    plan character varying DEFAULT 'trial'::character varying NOT NULL,
    onboarding_completed_at timestamp(6) without time zone,
    trial_ends_at timestamp(6) without time zone
);

ALTER TABLE ONLY public.accounts FORCE ROW LEVEL SECURITY;


--
-- Name: accounts_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.accounts_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: accounts_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.accounts_id_seq OWNED BY public.accounts.id;


--
-- Name: agent_coordination_signals; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.agent_coordination_signals (
    id bigint NOT NULL,
    source_agent_run_id bigint NOT NULL,
    target_agent_run_id bigint,
    parent_workflow_id character varying(255) NOT NULL,
    signal_type character varying(50) NOT NULL,
    payload jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp(6) without time zone NOT NULL
);

ALTER TABLE ONLY public.agent_coordination_signals FORCE ROW LEVEL SECURITY;


--
-- Name: agent_coordination_signals_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.agent_coordination_signals_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: agent_coordination_signals_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.agent_coordination_signals_id_seq OWNED BY public.agent_coordination_signals.id;


--
-- Name: agent_run_anomalies; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.agent_run_anomalies (
    id bigint NOT NULL,
    agent_run_id bigint NOT NULL,
    project_id bigint NOT NULL,
    anomaly_type character varying(50) NOT NULL,
    severity character varying(20) NOT NULL,
    metric_name character varying(50) NOT NULL,
    metric_value double precision NOT NULL,
    baseline_mean double precision NOT NULL,
    baseline_standard_deviation double precision NOT NULL,
    deviation_factor double precision NOT NULL,
    message text,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);

ALTER TABLE ONLY public.agent_run_anomalies FORCE ROW LEVEL SECURITY;


--
-- Name: agent_run_anomalies_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.agent_run_anomalies_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: agent_run_anomalies_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.agent_run_anomalies_id_seq OWNED BY public.agent_run_anomalies.id;


--
-- Name: agent_run_logs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.agent_run_logs (
    id bigint NOT NULL,
    agent_run_id bigint NOT NULL,
    log_type character varying(50) NOT NULL,
    content text NOT NULL,
    metadata jsonb,
    created_at timestamp(6) without time zone NOT NULL
);

ALTER TABLE ONLY public.agent_run_logs FORCE ROW LEVEL SECURITY;


--
-- Name: agent_run_logs_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.agent_run_logs_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: agent_run_logs_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.agent_run_logs_id_seq OWNED BY public.agent_run_logs.id;


--
-- Name: agent_run_phases; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.agent_run_phases (
    id bigint NOT NULL,
    agent_run_id bigint NOT NULL,
    phase_key character varying(100) NOT NULL,
    phase_group character varying(50) NOT NULL,
    status character varying(50) DEFAULT 'completed'::character varying NOT NULL,
    started_at timestamp(6) without time zone NOT NULL,
    finished_at timestamp(6) without time zone NOT NULL,
    duration_seconds integer DEFAULT 0 NOT NULL,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT agent_run_phases_duration_seconds_non_negative CHECK ((duration_seconds >= 0)),
    CONSTRAINT agent_run_phases_finished_at_after_started_at CHECK ((finished_at >= started_at))
);

ALTER TABLE ONLY public.agent_run_phases FORCE ROW LEVEL SECURITY;


--
-- Name: agent_run_phases_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.agent_run_phases_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: agent_run_phases_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.agent_run_phases_id_seq OWNED BY public.agent_run_phases.id;


--
-- Name: agent_runs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.agent_runs (
    id bigint NOT NULL,
    project_id bigint NOT NULL,
    issue_id bigint,
    temporal_workflow_id character varying(255),
    temporal_run_id character varying(255),
    agent_type character varying(50) NOT NULL,
    status character varying(50) DEFAULT 'pending'::character varying NOT NULL,
    worktree_path character varying(500),
    branch_name character varying(255),
    base_commit_sha character varying(40),
    result_commit_sha character varying(40),
    pull_request_url character varying(500),
    pull_request_number integer,
    error_message text,
    iterations integer DEFAULT 0,
    duration_seconds integer,
    tokens_input integer DEFAULT 0,
    tokens_output integer DEFAULT 0,
    cost_cents integer DEFAULT 0,
    started_at timestamp(6) without time zone,
    completed_at timestamp(6) without time zone,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    proxy_token character varying(64),
    container_id character varying(128),
    custom_prompt text,
    source_pull_request_number integer,
    prompt_version_id bigint,
    goal character varying(50) DEFAULT 'create_pr'::character varying NOT NULL,
    created_issue_url character varying(500),
    created_issue_number integer,
    service_container_ids jsonb DEFAULT '[]'::jsonb,
    service_environment jsonb DEFAULT '{}'::jsonb,
    auth_provider character varying(50),
    trigger_type character varying(50) DEFAULT 'automatic'::character varying NOT NULL,
    providers_attempted jsonb DEFAULT '[]'::jsonb NOT NULL,
    final_provider character varying(50),
    provider_switches integer DEFAULT 0 NOT NULL,
    rate_limited_until timestamp(6) without time zone,
    review_posted_at timestamp(6) without time zone,
    review_url character varying(500),
    peak_cpu_percent double precision,
    peak_memory_bytes bigint,
    avg_cpu_percent double precision,
    avg_memory_bytes numeric(20,4),
    container_metrics_count integer DEFAULT 0 NOT NULL,
    auto_pick boolean DEFAULT false NOT NULL,
    mcp_server_snapshot jsonb DEFAULT '[]'::jsonb NOT NULL,
    diagnosis_status character varying(50),
    diagnosis_issue_url character varying(500),
    container_retained_until timestamp(6) without time zone,
    provider_id bigint,
    stale_requeue_count integer DEFAULT 0 NOT NULL,
    parent_workflow_id character varying(255),
    token_limit_status character varying(50),
    guardrail_violation_type character varying(50),
    guardrail_context jsonb,
    paused_at timestamp(6) without time zone,
    count_toward_draft_review_round boolean DEFAULT false NOT NULL,
    expected_draft_review_count integer,
    priority_tier character varying(10),
    cross_repo_issues jsonb DEFAULT '[]'::jsonb,
    stale_skip_count integer DEFAULT 0 NOT NULL
);

ALTER TABLE ONLY public.agent_runs FORCE ROW LEVEL SECURITY;


--
-- Name: agent_runs_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.agent_runs_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: agent_runs_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.agent_runs_id_seq OWNED BY public.agent_runs.id;


--
-- Name: ar_internal_metadata; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.ar_internal_metadata (
    key character varying NOT NULL,
    value character varying,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: billing_invoices; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.billing_invoices (
    id bigint NOT NULL,
    account_id bigint NOT NULL,
    billing_period_id bigint NOT NULL,
    external_id character varying(255),
    status character varying(20) DEFAULT 'draft'::character varying NOT NULL,
    subtotal_cents integer DEFAULT 0 NOT NULL,
    tax_cents integer DEFAULT 0 NOT NULL,
    total_cents integer DEFAULT 0 NOT NULL,
    issued_at timestamp(6) without time zone,
    due_at timestamp(6) without time zone,
    paid_at timestamp(6) without time zone,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);

ALTER TABLE ONLY public.billing_invoices FORCE ROW LEVEL SECURITY;


--
-- Name: billing_invoices_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.billing_invoices_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: billing_invoices_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.billing_invoices_id_seq OWNED BY public.billing_invoices.id;


--
-- Name: billing_line_items; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.billing_line_items (
    id bigint NOT NULL,
    billing_invoice_id bigint NOT NULL,
    description character varying NOT NULL,
    line_item_type character varying(30) NOT NULL,
    quantity numeric(18,4) DEFAULT 0.0 NOT NULL,
    unit_price_cents integer DEFAULT 0 NOT NULL,
    total_cents integer DEFAULT 0 NOT NULL,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);

ALTER TABLE ONLY public.billing_line_items FORCE ROW LEVEL SECURITY;


--
-- Name: billing_line_items_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.billing_line_items_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: billing_line_items_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.billing_line_items_id_seq OWNED BY public.billing_line_items.id;


--
-- Name: billing_periods; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.billing_periods (
    id bigint NOT NULL,
    account_id bigint NOT NULL,
    billing_plan_id bigint NOT NULL,
    period_type character varying(20) NOT NULL,
    starts_at timestamp(6) without time zone NOT NULL,
    ends_at timestamp(6) without time zone NOT NULL,
    status character varying(20) DEFAULT 'open'::character varying NOT NULL,
    total_cost_cents integer DEFAULT 0 NOT NULL,
    total_input_tokens bigint DEFAULT 0 NOT NULL,
    total_output_tokens bigint DEFAULT 0 NOT NULL,
    total_runs integer DEFAULT 0 NOT NULL,
    total_compute_seconds integer DEFAULT 0 NOT NULL,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);

ALTER TABLE ONLY public.billing_periods FORCE ROW LEVEL SECURITY;


--
-- Name: billing_periods_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.billing_periods_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: billing_periods_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.billing_periods_id_seq OWNED BY public.billing_periods.id;


--
-- Name: billing_plans; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.billing_plans (
    id bigint NOT NULL,
    account_id bigint NOT NULL,
    name character varying(100) NOT NULL,
    billing_model character varying(30) NOT NULL,
    base_rate_cents integer DEFAULT 0 NOT NULL,
    per_token_rate_cents numeric(12,6) DEFAULT 0.0 NOT NULL,
    per_run_rate_cents integer DEFAULT 0 NOT NULL,
    per_project_rate_cents integer DEFAULT 0 NOT NULL,
    included_tokens bigint DEFAULT 0 NOT NULL,
    included_runs integer DEFAULT 0 NOT NULL,
    included_projects integer DEFAULT 0 NOT NULL,
    period_type character varying(20) NOT NULL,
    active boolean DEFAULT true NOT NULL,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);

ALTER TABLE ONLY public.billing_plans FORCE ROW LEVEL SECURITY;


--
-- Name: billing_plans_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.billing_plans_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: billing_plans_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.billing_plans_id_seq OWNED BY public.billing_plans.id;


--
-- Name: chat_messages; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.chat_messages (
    id bigint NOT NULL,
    chat_session_id bigint NOT NULL,
    external_id uuid DEFAULT gen_random_uuid() NOT NULL,
    role character varying NOT NULL,
    content text,
    tool_call_id character varying,
    tool_name character varying,
    tool_arguments jsonb,
    tool_result jsonb,
    model character varying,
    tokens_input integer,
    tokens_output integer,
    metadata jsonb DEFAULT '{}'::jsonb,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);

ALTER TABLE ONLY public.chat_messages FORCE ROW LEVEL SECURITY;


--
-- Name: chat_messages_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.chat_messages_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: chat_messages_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.chat_messages_id_seq OWNED BY public.chat_messages.id;


--
-- Name: chat_session_projects; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.chat_session_projects (
    id bigint NOT NULL,
    chat_session_id bigint NOT NULL,
    project_id bigint NOT NULL,
    context_type character varying DEFAULT 'reference'::character varying NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);

ALTER TABLE ONLY public.chat_session_projects FORCE ROW LEVEL SECURITY;


--
-- Name: chat_session_projects_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.chat_session_projects_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: chat_session_projects_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.chat_session_projects_id_seq OWNED BY public.chat_session_projects.id;


--
-- Name: chat_sessions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.chat_sessions (
    id bigint NOT NULL,
    account_id bigint NOT NULL,
    project_id bigint,
    provider_id bigint,
    external_id uuid DEFAULT gen_random_uuid() NOT NULL,
    status character varying DEFAULT 'active'::character varying NOT NULL,
    mode character varying DEFAULT 'api'::character varying NOT NULL,
    model character varying,
    system_prompt text,
    container_id character varying,
    workspace_volume character varying,
    metadata jsonb DEFAULT '{}'::jsonb,
    idle_timeout_at timestamp(6) without time zone,
    created_by_id bigint,
    title character varying,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);

ALTER TABLE ONLY public.chat_sessions FORCE ROW LEVEL SECURITY;


--
-- Name: chat_sessions_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.chat_sessions_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: chat_sessions_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.chat_sessions_id_seq OWNED BY public.chat_sessions.id;


--
-- Name: collector_runs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.collector_runs (
    id bigint NOT NULL,
    project_version_id bigint NOT NULL,
    collector_type character varying(100) NOT NULL,
    status character varying(50) DEFAULT 'pending'::character varying NOT NULL,
    started_at timestamp(6) without time zone,
    completed_at timestamp(6) without time zone,
    duration_ms integer,
    artifacts_count integer DEFAULT 0,
    error_message text,
    tool_version character varying(100),
    metadata jsonb DEFAULT '{}'::jsonb,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);

ALTER TABLE ONLY public.collector_runs FORCE ROW LEVEL SECURITY;


--
-- Name: collector_runs_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.collector_runs_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: collector_runs_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.collector_runs_id_seq OWNED BY public.collector_runs.id;


--
-- Name: configuration_experiment_assignments; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.configuration_experiment_assignments (
    id bigint NOT NULL,
    configuration_experiment_id bigint NOT NULL,
    configuration_experiment_variant_id bigint NOT NULL,
    agent_run_id bigint NOT NULL,
    quality_score numeric(5,4),
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: configuration_experiment_assignments_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.configuration_experiment_assignments_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: configuration_experiment_assignments_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.configuration_experiment_assignments_id_seq OWNED BY public.configuration_experiment_assignments.id;


--
-- Name: configuration_experiment_variants; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.configuration_experiment_variants (
    id bigint NOT NULL,
    configuration_experiment_id bigint NOT NULL,
    config_value text NOT NULL,
    is_control boolean DEFAULT false NOT NULL,
    sample_count integer DEFAULT 0 NOT NULL,
    total_quality_score numeric(10,4) DEFAULT 0 NOT NULL,
    avg_quality_score numeric(5,4),
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: configuration_experiment_variants_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.configuration_experiment_variants_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: configuration_experiment_variants_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.configuration_experiment_variants_id_seq OWNED BY public.configuration_experiment_variants.id;


--
-- Name: configuration_experiments; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.configuration_experiments (
    id bigint NOT NULL,
    account_id bigint,
    name character varying NOT NULL,
    description text,
    config_key character varying NOT NULL,
    status character varying(50) DEFAULT 'draft'::character varying NOT NULL,
    control_value text NOT NULL,
    experiment_type character varying(50) NOT NULL,
    min_samples_per_variant integer DEFAULT 30 NOT NULL,
    confidence_threshold numeric(5,4) DEFAULT 0.95 NOT NULL,
    traffic_percentage integer DEFAULT 100 NOT NULL,
    cached_analysis jsonb,
    analysis_samples_key character varying,
    started_at timestamp without time zone,
    completed_at timestamp without time zone,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    winner_variant_id bigint
);


--
-- Name: configuration_experiments_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.configuration_experiments_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: configuration_experiments_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.configuration_experiments_id_seq OWNED BY public.configuration_experiments.id;


--
-- Name: container_metrics; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.container_metrics (
    id bigint NOT NULL,
    agent_run_id bigint NOT NULL,
    container_id character varying(128) NOT NULL,
    cpu_percent double precision DEFAULT 0.0 NOT NULL,
    memory_bytes bigint DEFAULT 0 NOT NULL,
    memory_limit_bytes bigint DEFAULT 0 NOT NULL,
    memory_percent double precision DEFAULT 0.0 NOT NULL,
    pids_count integer,
    recorded_at timestamp(6) without time zone NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);

ALTER TABLE ONLY public.container_metrics FORCE ROW LEVEL SECURITY;


--
-- Name: container_metrics_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.container_metrics_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: container_metrics_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.container_metrics_id_seq OWNED BY public.container_metrics.id;


--
-- Name: container_pool_entries; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.container_pool_entries (
    id bigint NOT NULL,
    project_id bigint NOT NULL,
    agent_run_id bigint,
    container_id character varying(128),
    status character varying(20) NOT NULL,
    workspace_volume character varying(128) NOT NULL,
    image character varying NOT NULL,
    network character varying(64) NOT NULL,
    warmed_at timestamp without time zone,
    claimed_at timestamp without time zone,
    last_error text,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);

ALTER TABLE ONLY public.container_pool_entries FORCE ROW LEVEL SECURITY;


--
-- Name: container_pool_entries_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.container_pool_entries_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: container_pool_entries_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.container_pool_entries_id_seq OWNED BY public.container_pool_entries.id;


--
-- Name: context_intake_responses; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.context_intake_responses (
    id bigint NOT NULL,
    context_intake_session_id bigint NOT NULL,
    question_key character varying(200) NOT NULL,
    question_text text NOT NULL,
    answer_text text,
    answer_data jsonb DEFAULT '{}'::jsonb,
    section character varying(100) NOT NULL,
    sequence integer DEFAULT 0 NOT NULL,
    is_follow_up boolean DEFAULT false,
    parent_response_id bigint,
    skipped boolean DEFAULT false,
    provenance character varying(50) DEFAULT 'human'::character varying,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);

ALTER TABLE ONLY public.context_intake_responses FORCE ROW LEVEL SECURITY;


--
-- Name: context_intake_responses_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.context_intake_responses_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: context_intake_responses_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.context_intake_responses_id_seq OWNED BY public.context_intake_responses.id;


--
-- Name: context_intake_sessions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.context_intake_sessions (
    id bigint NOT NULL,
    project_id bigint NOT NULL,
    started_by_id bigint NOT NULL,
    status character varying(50) DEFAULT 'in_progress'::character varying NOT NULL,
    schema_version character varying(20) DEFAULT '1.0'::character varying NOT NULL,
    current_step integer DEFAULT 0,
    completed_at timestamp(6) without time zone,
    stale_at timestamp(6) without time zone,
    metadata jsonb DEFAULT '{}'::jsonb,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);

ALTER TABLE ONLY public.context_intake_sessions FORCE ROW LEVEL SECURITY;


--
-- Name: context_intake_sessions_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.context_intake_sessions_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: context_intake_sessions_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.context_intake_sessions_id_seq OWNED BY public.context_intake_sessions.id;


--
-- Name: cost_budgets; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.cost_budgets (
    id bigint NOT NULL,
    project_id bigint NOT NULL,
    budget_type character varying(50) NOT NULL,
    limit_cents integer NOT NULL,
    current_usage_cents integer DEFAULT 0 NOT NULL,
    alert_threshold_percent integer DEFAULT 80 NOT NULL,
    alert_sent_at timestamp(6) without time zone,
    period_started_at timestamp(6) without time zone,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    enforcement_mode character varying(20) DEFAULT 'alert'::character varying NOT NULL,
    grace_buffer_percent integer DEFAULT 0 NOT NULL
);

ALTER TABLE ONLY public.cost_budgets FORCE ROW LEVEL SECURITY;


--
-- Name: cost_budgets_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.cost_budgets_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: cost_budgets_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.cost_budgets_id_seq OWNED BY public.cost_budgets.id;


--
-- Name: decision_record_links; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.decision_record_links (
    id bigint NOT NULL,
    decision_record_id bigint NOT NULL,
    linkable_type character varying(100) NOT NULL,
    linkable_id character varying(100) NOT NULL,
    link_type character varying(50) NOT NULL,
    created_at timestamp(6) without time zone NOT NULL
);

ALTER TABLE ONLY public.decision_record_links FORCE ROW LEVEL SECURITY;


--
-- Name: decision_record_links_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.decision_record_links_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: decision_record_links_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.decision_record_links_id_seq OWNED BY public.decision_record_links.id;


--
-- Name: decision_records; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.decision_records (
    id bigint NOT NULL,
    project_id bigint NOT NULL,
    agent_run_id bigint,
    issue_id bigint,
    title character varying(500) NOT NULL,
    summary text NOT NULL,
    context text,
    decision text NOT NULL,
    consequences text,
    status character varying(50) DEFAULT 'draft'::character varying NOT NULL,
    superseded_by_id bigint,
    commit_sha_start character varying(40),
    commit_sha_end character varying(40),
    tags jsonb DEFAULT '[]'::jsonb NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);

ALTER TABLE ONLY public.decision_records FORCE ROW LEVEL SECURITY;


--
-- Name: decision_records_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.decision_records_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: decision_records_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.decision_records_id_seq OWNED BY public.decision_records.id;


--
-- Name: flipper_features; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.flipper_features (
    id bigint NOT NULL,
    key character varying NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: flipper_features_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.flipper_features_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: flipper_features_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.flipper_features_id_seq OWNED BY public.flipper_features.id;


--
-- Name: flipper_gates; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.flipper_gates (
    id bigint NOT NULL,
    feature_key character varying NOT NULL,
    key character varying NOT NULL,
    value text,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: flipper_gates_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.flipper_gates_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: flipper_gates_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.flipper_gates_id_seq OWNED BY public.flipper_gates.id;


--
-- Name: github_tokens; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.github_tokens (
    id bigint NOT NULL,
    account_id bigint NOT NULL,
    created_by_id bigint,
    name character varying NOT NULL,
    token text NOT NULL,
    scopes jsonb DEFAULT '[]'::jsonb NOT NULL,
    expires_at timestamp(6) without time zone,
    last_used_at timestamp(6) without time zone,
    revoked_at timestamp(6) without time zone,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    accessible_repositories jsonb DEFAULT '[]'::jsonb NOT NULL,
    repositories_synced_at timestamp(6) without time zone,
    validation_status character varying(50) DEFAULT 'pending'::character varying NOT NULL,
    validation_error text,
    projects_count integer DEFAULT 0 NOT NULL
);

ALTER TABLE ONLY public.github_tokens FORCE ROW LEVEL SECURITY;


--
-- Name: github_tokens_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.github_tokens_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: github_tokens_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.github_tokens_id_seq OWNED BY public.github_tokens.id;


--
-- Name: good_job_batches; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.good_job_batches (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    description text,
    serialized_properties jsonb,
    on_finish text,
    on_success text,
    on_discard text,
    callback_queue_name text,
    callback_priority integer,
    enqueued_at timestamp(6) without time zone,
    discarded_at timestamp(6) without time zone,
    finished_at timestamp(6) without time zone,
    jobs_finished_at timestamp(6) without time zone
);


--
-- Name: good_job_executions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.good_job_executions (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    active_job_id uuid NOT NULL,
    job_class text,
    queue_name text,
    serialized_params jsonb,
    scheduled_at timestamp(6) without time zone,
    finished_at timestamp(6) without time zone,
    error text,
    error_event smallint,
    error_backtrace text[],
    process_id uuid,
    duration interval
);


--
-- Name: good_job_processes; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.good_job_processes (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    state jsonb,
    lock_type smallint
);


--
-- Name: good_job_settings; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.good_job_settings (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    key text,
    value jsonb
);


--
-- Name: good_jobs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.good_jobs (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    queue_name text,
    priority integer,
    serialized_params jsonb,
    scheduled_at timestamp(6) without time zone,
    performed_at timestamp(6) without time zone,
    finished_at timestamp(6) without time zone,
    error text,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    active_job_id uuid,
    concurrency_key text,
    cron_key text,
    retried_good_job_id uuid,
    cron_at timestamp(6) without time zone,
    batch_id uuid,
    batch_callback_id uuid,
    is_discrete boolean,
    executions_count integer,
    job_class text,
    error_event smallint,
    labels text[],
    locked_by_id uuid,
    locked_at timestamp(6) without time zone
);


--
-- Name: integration_credentials; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.integration_credentials (
    id bigint NOT NULL,
    account_id bigint NOT NULL,
    created_by_id bigint,
    name character varying NOT NULL,
    service_key character varying NOT NULL,
    category character varying NOT NULL,
    auth_kind character varying NOT NULL,
    secret text NOT NULL,
    expires_at timestamp(6) without time zone,
    last_used_at timestamp(6) without time zone,
    revoked_at timestamp(6) without time zone,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);

ALTER TABLE ONLY public.integration_credentials FORCE ROW LEVEL SECURITY;


--
-- Name: integration_credentials_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.integration_credentials_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: integration_credentials_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.integration_credentials_id_seq OWNED BY public.integration_credentials.id;


--
-- Name: issue_dependencies; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.issue_dependencies (
    id bigint NOT NULL,
    issue_id bigint NOT NULL,
    depends_on_issue_id bigint,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    depends_on_owner character varying,
    depends_on_repo character varying,
    depends_on_number integer,
    requires_deployment boolean DEFAULT false NOT NULL,
    CONSTRAINT issue_dependencies_depends_on_xor CHECK ((((depends_on_issue_id IS NOT NULL) AND (depends_on_owner IS NULL) AND (depends_on_repo IS NULL) AND (depends_on_number IS NULL)) OR ((depends_on_issue_id IS NULL) AND (NULLIF((depends_on_owner)::text, ''::text) IS NOT NULL) AND (NULLIF((depends_on_repo)::text, ''::text) IS NOT NULL) AND (depends_on_number > 0))))
);

ALTER TABLE ONLY public.issue_dependencies FORCE ROW LEVEL SECURITY;


--
-- Name: issue_dependencies_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.issue_dependencies_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: issue_dependencies_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.issue_dependencies_id_seq OWNED BY public.issue_dependencies.id;


--
-- Name: issues; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.issues (
    id bigint NOT NULL,
    project_id bigint NOT NULL,
    parent_issue_id bigint,
    github_issue_id bigint NOT NULL,
    github_number integer NOT NULL,
    title character varying(1000) NOT NULL,
    body text,
    github_state character varying NOT NULL,
    labels jsonb DEFAULT '[]'::jsonb NOT NULL,
    paid_state character varying DEFAULT 'new'::character varying NOT NULL,
    github_created_at timestamp(6) without time zone NOT NULL,
    github_updated_at timestamp(6) without time zone NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    is_pull_request boolean DEFAULT false NOT NULL,
    github_creator_login character varying,
    pr_followup_count integer DEFAULT 0 NOT NULL,
    pr_review_phase character varying DEFAULT 'draft'::character varying NOT NULL,
    draft_review_count integer DEFAULT 0 NOT NULL,
    source character varying DEFAULT 'github'::character varying NOT NULL,
    auto_continue_paused boolean DEFAULT false NOT NULL,
    last_pr_scan_at timestamp(6) without time zone,
    relationships_parsed_at timestamp(6) without time zone,
    review_goal_retry_count integer DEFAULT 0 NOT NULL,
    review_goal_retry_reset_at timestamp(6) without time zone,
    operational_failure_reset_at timestamp(6) without time zone,
    ci_action_dispatched_at timestamp(6) without time zone,
    deployed_at timestamp(6) without time zone,
    enhance_issue_rounds integer DEFAULT 0 NOT NULL,
    ci_retry_requested_at timestamp(6) without time zone
);

ALTER TABLE ONLY public.issues FORCE ROW LEVEL SECURITY;


--
-- Name: issues_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.issues_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: issues_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.issues_id_seq OWNED BY public.issues.id;


--
-- Name: knowledge_artifacts; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.knowledge_artifacts (
    id bigint NOT NULL,
    collector_run_id bigint NOT NULL,
    project_id bigint NOT NULL,
    artifact_type character varying(100) NOT NULL,
    scope_path character varying(1000),
    identifier character varying(500),
    content text,
    content_hash character varying(64) NOT NULL,
    metadata jsonb DEFAULT '{}'::jsonb,
    status character varying(50) DEFAULT 'active'::character varying NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    collector_type character varying(100) NOT NULL
);

ALTER TABLE ONLY public.knowledge_artifacts FORCE ROW LEVEL SECURITY;


--
-- Name: knowledge_artifacts_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.knowledge_artifacts_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: knowledge_artifacts_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.knowledge_artifacts_id_seq OWNED BY public.knowledge_artifacts.id;


--
-- Name: knowledge_audit_events; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.knowledge_audit_events (
    id bigint NOT NULL,
    project_id bigint NOT NULL,
    event_type character varying(100) NOT NULL,
    actor_type character varying(50),
    actor_id character varying(100),
    target_type character varying(100),
    target_id character varying(100),
    details jsonb DEFAULT '{}'::jsonb,
    created_at timestamp(6) without time zone NOT NULL
);

ALTER TABLE ONLY public.knowledge_audit_events FORCE ROW LEVEL SECURITY;


--
-- Name: knowledge_audit_events_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.knowledge_audit_events_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: knowledge_audit_events_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.knowledge_audit_events_id_seq OWNED BY public.knowledge_audit_events.id;


--
-- Name: knowledge_chunks; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.knowledge_chunks (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    knowledge_artifact_id bigint NOT NULL,
    project_id bigint NOT NULL,
    chunk_type character varying(50) NOT NULL,
    content text NOT NULL,
    content_hash character varying(64) NOT NULL,
    embedding_model character varying(100),
    scope_tags jsonb DEFAULT '[]'::jsonb,
    status character varying(50) DEFAULT 'active'::character varying NOT NULL,
    sequence integer DEFAULT 0,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    content_tsvector tsvector,
    redaction_scanned_at timestamp(6) without time zone
);

ALTER TABLE ONLY public.knowledge_chunks FORCE ROW LEVEL SECURITY;


--
-- Name: knowledge_links; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.knowledge_links (
    id bigint NOT NULL,
    source_chunk_id uuid NOT NULL,
    target_chunk_id uuid NOT NULL,
    link_type character varying(50) NOT NULL,
    weight numeric(5,3) DEFAULT 1.0,
    metadata jsonb DEFAULT '{}'::jsonb,
    created_at timestamp(6) without time zone NOT NULL
);

ALTER TABLE ONLY public.knowledge_links FORCE ROW LEVEL SECURITY;


--
-- Name: knowledge_links_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.knowledge_links_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: knowledge_links_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.knowledge_links_id_seq OWNED BY public.knowledge_links.id;


--
-- Name: knowledge_recommendations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.knowledge_recommendations (
    id bigint NOT NULL,
    project_id bigint NOT NULL,
    recommendation_type character varying(50) NOT NULL,
    collector_type character varying(100),
    priority character varying(20) DEFAULT 'medium'::character varying NOT NULL,
    description text,
    evidence jsonb DEFAULT '{}'::jsonb NOT NULL,
    status character varying(20) DEFAULT 'pending'::character varying NOT NULL,
    dismissed_at timestamp(6) without time zone,
    dismissal_reason text,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);

ALTER TABLE ONLY public.knowledge_recommendations FORCE ROW LEVEL SECURITY;


--
-- Name: knowledge_recommendations_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.knowledge_recommendations_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: knowledge_recommendations_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.knowledge_recommendations_id_seq OWNED BY public.knowledge_recommendations.id;


--
-- Name: knowledge_runs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.knowledge_runs (
    id bigint NOT NULL,
    project_id bigint NOT NULL,
    operation_type character varying(50) NOT NULL,
    status character varying(50) DEFAULT 'pending'::character varying NOT NULL,
    final_provider character varying(50),
    provider_attempts jsonb DEFAULT '[]'::jsonb NOT NULL,
    total_tokens integer DEFAULT 0 NOT NULL,
    proxy_token character varying(64),
    token_limit_status character varying(50),
    max_tokens integer,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);

ALTER TABLE ONLY public.knowledge_runs FORCE ROW LEVEL SECURITY;


--
-- Name: knowledge_runs_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.knowledge_runs_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: knowledge_runs_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.knowledge_runs_id_seq OWNED BY public.knowledge_runs.id;


--
-- Name: knowledge_usage_stats; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.knowledge_usage_stats (
    id bigint NOT NULL,
    agent_run_id bigint NOT NULL,
    project_id bigint NOT NULL,
    artifact_type character varying(100) NOT NULL,
    goal character varying(50) NOT NULL,
    context_type character varying(50) NOT NULL,
    artifact_count integer DEFAULT 0 NOT NULL,
    chunk_count integer DEFAULT 0 NOT NULL,
    token_count integer DEFAULT 0 NOT NULL,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);

ALTER TABLE ONLY public.knowledge_usage_stats FORCE ROW LEVEL SECURITY;


--
-- Name: knowledge_usage_stats_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.knowledge_usage_stats_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: knowledge_usage_stats_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.knowledge_usage_stats_id_seq OWNED BY public.knowledge_usage_stats.id;


--
-- Name: linear_tokens; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.linear_tokens (
    id bigint NOT NULL,
    account_id bigint NOT NULL,
    created_by_id bigint,
    name character varying NOT NULL,
    token text NOT NULL,
    validation_status character varying DEFAULT 'pending'::character varying NOT NULL,
    validation_error character varying,
    last_used_at timestamp(6) without time zone,
    revoked_at timestamp(6) without time zone,
    expires_at timestamp(6) without time zone,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);

ALTER TABLE ONLY public.linear_tokens FORCE ROW LEVEL SECURITY;


--
-- Name: linear_tokens_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.linear_tokens_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: linear_tokens_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.linear_tokens_id_seq OWNED BY public.linear_tokens.id;


--
-- Name: llm_models; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.llm_models (
    id bigint NOT NULL,
    model_id character varying NOT NULL,
    display_name character varying NOT NULL,
    provider character varying(50) NOT NULL,
    family character varying(100),
    category character varying(50) DEFAULT 'general'::character varying NOT NULL,
    context_window integer,
    max_output_tokens integer,
    input_cost_per_million numeric(10,4),
    output_cost_per_million numeric(10,4),
    supports_vision boolean DEFAULT false NOT NULL,
    supports_tools boolean DEFAULT false NOT NULL,
    supports_json_output boolean DEFAULT false NOT NULL,
    capability_score numeric(4,2),
    active boolean DEFAULT true NOT NULL,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    tier character varying(10),
    CONSTRAINT llm_models_tier_check CHECK (((tier IS NULL) OR ((tier)::text = ANY (ARRAY[('low'::character varying)::text, ('mid'::character varying)::text, ('high'::character varying)::text]))))
);


--
-- Name: llm_models_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.llm_models_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: llm_models_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.llm_models_id_seq OWNED BY public.llm_models.id;


--
-- Name: llm_output_metrics; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.llm_output_metrics (
    id bigint NOT NULL,
    project_id bigint NOT NULL,
    account_id bigint NOT NULL,
    output_type character varying(30) NOT NULL,
    prompt_slug character varying(100) NOT NULL,
    source_id bigint NOT NULL,
    source_type character varying(30) NOT NULL,
    prompt_version_id bigint,
    scores jsonb DEFAULT '{}'::jsonb NOT NULL,
    composite_score numeric(5,4),
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);

ALTER TABLE ONLY public.llm_output_metrics FORCE ROW LEVEL SECURITY;


--
-- Name: llm_output_metrics_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.llm_output_metrics_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: llm_output_metrics_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.llm_output_metrics_id_seq OWNED BY public.llm_output_metrics.id;


--
-- Name: mcp_server_definitions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.mcp_server_definitions (
    id bigint NOT NULL,
    account_id bigint NOT NULL,
    name character varying(255) NOT NULL,
    transport character varying(50) NOT NULL,
    install_type character varying(50) NOT NULL,
    command character varying(500),
    args jsonb DEFAULT '[]'::jsonb NOT NULL,
    url character varying(2048),
    image character varying(500),
    env jsonb DEFAULT '{}'::jsonb NOT NULL,
    enabled boolean DEFAULT true NOT NULL,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);

ALTER TABLE ONLY public.mcp_server_definitions FORCE ROW LEVEL SECURITY;


--
-- Name: mcp_server_definitions_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.mcp_server_definitions_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: mcp_server_definitions_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.mcp_server_definitions_id_seq OWNED BY public.mcp_server_definitions.id;


--
-- Name: model_selections; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.model_selections (
    id bigint NOT NULL,
    agent_run_id bigint NOT NULL,
    llm_model_id bigint NOT NULL,
    selector_type character varying(50) NOT NULL,
    reasoning text,
    candidates jsonb DEFAULT '[]'::jsonb NOT NULL,
    budget_limit_cents integer,
    complexity_score numeric(4,2),
    selection_duration_ms integer,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    tier character varying(10),
    escalated_from_tier character varying(10),
    escalated_reason character varying(255),
    CONSTRAINT model_selections_escalated_from_tier_check CHECK (((escalated_from_tier IS NULL) OR ((escalated_from_tier)::text = ANY (ARRAY[('low'::character varying)::text, ('mid'::character varying)::text, ('high'::character varying)::text])))),
    CONSTRAINT model_selections_tier_check CHECK (((tier IS NULL) OR ((tier)::text = ANY (ARRAY[('low'::character varying)::text, ('mid'::character varying)::text, ('high'::character varying)::text]))))
);

ALTER TABLE ONLY public.model_selections FORCE ROW LEVEL SECURITY;


--
-- Name: model_selections_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.model_selections_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: model_selections_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.model_selections_id_seq OWNED BY public.model_selections.id;


--
-- Name: notification_rule_states; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.notification_rule_states (
    id bigint NOT NULL,
    account_id bigint NOT NULL,
    source character varying NOT NULL,
    subject_type character varying NOT NULL,
    subject_id bigint NOT NULL,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    first_seen_at timestamp(6) without time zone,
    last_seen_at timestamp(6) without time zone,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);

ALTER TABLE ONLY public.notification_rule_states FORCE ROW LEVEL SECURITY;


--
-- Name: notification_rule_states_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.notification_rule_states_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: notification_rule_states_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.notification_rule_states_id_seq OWNED BY public.notification_rule_states.id;


--
-- Name: notifications; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.notifications (
    id bigint NOT NULL,
    account_id bigint NOT NULL,
    user_id bigint,
    subject_type character varying,
    subject_id bigint,
    source character varying NOT NULL,
    severity integer DEFAULT 0 NOT NULL,
    title character varying NOT NULL,
    description text,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    action_url character varying,
    nav_section character varying,
    read_at timestamp(6) without time zone,
    dismissed_at timestamp(6) without time zone,
    resolved_at timestamp(6) without time zone,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);

ALTER TABLE ONLY public.notifications FORCE ROW LEVEL SECURITY;


--
-- Name: notifications_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.notifications_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: notifications_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.notifications_id_seq OWNED BY public.notifications.id;


--
-- Name: onboarding_steps; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.onboarding_steps (
    id bigint NOT NULL,
    account_id bigint NOT NULL,
    step character varying NOT NULL,
    "position" integer NOT NULL,
    status character varying DEFAULT 'pending'::character varying NOT NULL,
    completed_at timestamp(6) without time zone,
    metadata jsonb DEFAULT '{}'::jsonb,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);

ALTER TABLE ONLY public.onboarding_steps FORCE ROW LEVEL SECURITY;


--
-- Name: onboarding_steps_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.onboarding_steps_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: onboarding_steps_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.onboarding_steps_id_seq OWNED BY public.onboarding_steps.id;


--
-- Name: pr_templates; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.pr_templates (
    id bigint NOT NULL,
    account_id bigint NOT NULL,
    project_id bigint,
    user_id bigint,
    name character varying(255) NOT NULL,
    pr_type character varying(50) DEFAULT 'default'::character varying NOT NULL,
    body text NOT NULL,
    description text,
    "position" integer DEFAULT 0 NOT NULL,
    enabled boolean DEFAULT true NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT pr_templates_scope_check CHECK ((NOT ((project_id IS NOT NULL) AND (user_id IS NOT NULL))))
);

ALTER TABLE ONLY public.pr_templates FORCE ROW LEVEL SECURITY;


--
-- Name: pr_templates_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.pr_templates_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: pr_templates_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.pr_templates_id_seq OWNED BY public.pr_templates.id;


--
-- Name: pre_commit_requirements; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.pre_commit_requirements (
    id bigint NOT NULL,
    account_id bigint NOT NULL,
    project_id bigint,
    user_id bigint,
    name character varying(255) NOT NULL,
    command text NOT NULL,
    check_type character varying(50) DEFAULT 'shell_command'::character varying NOT NULL,
    fix_command text,
    failure_behavior character varying(50) DEFAULT 'block'::character varying NOT NULL,
    "position" integer DEFAULT 0 NOT NULL,
    enabled boolean DEFAULT true NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT chk_pre_commit_requirements_exclusive_scope CHECK ((NOT ((project_id IS NOT NULL) AND (user_id IS NOT NULL))))
);

ALTER TABLE ONLY public.pre_commit_requirements FORCE ROW LEVEL SECURITY;


--
-- Name: pre_commit_requirements_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.pre_commit_requirements_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: pre_commit_requirements_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.pre_commit_requirements_id_seq OWNED BY public.pre_commit_requirements.id;


--
-- Name: project_baselines; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.project_baselines (
    id bigint NOT NULL,
    project_id bigint NOT NULL,
    metric_name character varying(50) NOT NULL,
    mean double precision DEFAULT 0.0 NOT NULL,
    standard_deviation double precision DEFAULT 0.0 NOT NULL,
    sample_count integer DEFAULT 0 NOT NULL,
    p95 double precision DEFAULT 0.0 NOT NULL,
    last_calculated_at timestamp(6) without time zone,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);

ALTER TABLE ONLY public.project_baselines FORCE ROW LEVEL SECURITY;


--
-- Name: project_baselines_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.project_baselines_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: project_baselines_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.project_baselines_id_seq OWNED BY public.project_baselines.id;


--
-- Name: project_mcp_servers; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.project_mcp_servers (
    id bigint NOT NULL,
    project_id bigint NOT NULL,
    mcp_server_definition_id bigint NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);

ALTER TABLE ONLY public.project_mcp_servers FORCE ROW LEVEL SECURITY;


--
-- Name: project_mcp_servers_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.project_mcp_servers_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: project_mcp_servers_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.project_mcp_servers_id_seq OWNED BY public.project_mcp_servers.id;


--
-- Name: project_memberships; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.project_memberships (
    id bigint NOT NULL,
    user_id bigint NOT NULL,
    project_id bigint NOT NULL,
    role integer DEFAULT 0 NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);

ALTER TABLE ONLY public.project_memberships FORCE ROW LEVEL SECURITY;


--
-- Name: project_memberships_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.project_memberships_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: project_memberships_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.project_memberships_id_seq OWNED BY public.project_memberships.id;


--
-- Name: project_service_containers; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.project_service_containers (
    id bigint NOT NULL,
    project_id bigint NOT NULL,
    service_container_id bigint NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);

ALTER TABLE ONLY public.project_service_containers FORCE ROW LEVEL SECURITY;


--
-- Name: project_service_containers_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.project_service_containers_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: project_service_containers_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.project_service_containers_id_seq OWNED BY public.project_service_containers.id;


--
-- Name: project_versions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.project_versions (
    id bigint NOT NULL,
    project_id bigint NOT NULL,
    commit_sha character varying(40) NOT NULL,
    parent_sha character varying(40),
    branch character varying DEFAULT 'main'::character varying NOT NULL,
    committed_at timestamp(6) without time zone,
    metadata jsonb DEFAULT '{}'::jsonb,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);

ALTER TABLE ONLY public.project_versions FORCE ROW LEVEL SECURITY;


--
-- Name: project_versions_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.project_versions_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: project_versions_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.project_versions_id_seq OWNED BY public.project_versions.id;


--
-- Name: projects; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.projects (
    id bigint NOT NULL,
    account_id bigint NOT NULL,
    github_token_id bigint NOT NULL,
    created_by_id bigint,
    github_id bigint NOT NULL,
    owner character varying NOT NULL,
    repo character varying NOT NULL,
    default_branch character varying DEFAULT 'main'::character varying NOT NULL,
    name character varying NOT NULL,
    active boolean DEFAULT true NOT NULL,
    poll_interval_seconds integer DEFAULT 60 NOT NULL,
    label_mappings jsonb DEFAULT '{}'::jsonb NOT NULL,
    total_cost_cents bigint DEFAULT 0 NOT NULL,
    total_tokens_used bigint DEFAULT 0 NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    allowed_github_usernames jsonb DEFAULT '[]'::jsonb NOT NULL,
    auto_scan_prs boolean DEFAULT true NOT NULL,
    max_pr_followup_runs integer DEFAULT 8 NOT NULL,
    pr_action_labels jsonb DEFAULT '[]'::jsonb NOT NULL,
    auto_fix_merge_conflicts boolean DEFAULT true NOT NULL,
    last_agent_run_at timestamp(6) without time zone,
    last_github_activity_at timestamp(6) without time zone,
    owner_reviewer_login character varying,
    merge_method character varying DEFAULT 'squash'::character varying NOT NULL,
    max_draft_review_rounds integer DEFAULT 10 NOT NULL,
    last_polled_at timestamp(6) without time zone,
    auto_pick_enabled boolean DEFAULT false NOT NULL,
    model_preferences jsonb DEFAULT '{}'::jsonb NOT NULL,
    auto_scan_security boolean DEFAULT false NOT NULL,
    security_alert_types jsonb DEFAULT '["code_scanning"]'::jsonb NOT NULL,
    generated_label_name character varying DEFAULT 'paid-generated'::character varying NOT NULL,
    automation_label_name character varying DEFAULT 'paid-automation'::character varying NOT NULL,
    auto_add_labels_enabled boolean DEFAULT true NOT NULL,
    automation_on_label_enabled boolean DEFAULT true NOT NULL,
    webhook_secret text,
    knowledge_status character varying(50) DEFAULT 'pending'::character varying NOT NULL,
    last_code_scanning_scan_at timestamp(6) without time zone,
    code_scanning_interval_hours integer DEFAULT 72 NOT NULL,
    review_settings jsonb DEFAULT '{}'::jsonb NOT NULL,
    pr_aggregation_enabled boolean DEFAULT false NOT NULL,
    max_tokens_per_run integer,
    token_limit_warning_threshold integer DEFAULT 80 NOT NULL,
    max_execution_seconds integer DEFAULT 3600 NOT NULL,
    last_issue_sync_at timestamp(6) without time zone,
    priority_labels jsonb DEFAULT '{"P1": "P1", "P2": "P2", "P3": "P3"}'::jsonb NOT NULL,
    inherit_priority_labels boolean DEFAULT true NOT NULL,
    auto_release_granularity character varying DEFAULT 'off'::character varying NOT NULL,
    fitness_settings jsonb DEFAULT '{}'::jsonb NOT NULL,
    quality_paused_at timestamp(6) without time zone,
    quality_pause_metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    quality_gate_settings jsonb DEFAULT '{}'::jsonb NOT NULL,
    auto_merge_mode character varying DEFAULT 'off'::character varying NOT NULL,
    enhance_issue_needs_input_label_name character varying DEFAULT 'paid-needs-input'::character varying NOT NULL,
    enhance_issue_enhanced_label_name character varying DEFAULT 'paid-enhanced'::character varying NOT NULL,
    max_enhance_issue_reevaluation_rounds integer DEFAULT 3 NOT NULL,
    auto_enhance_enabled boolean DEFAULT false NOT NULL,
    scheduler_paused_at timestamp(6) without time zone,
    scheduler_pause_reason character varying,
    knowledge_evolution_enabled boolean DEFAULT false NOT NULL
);

ALTER TABLE ONLY public.projects FORCE ROW LEVEL SECURITY;


--
-- Name: projects_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.projects_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: projects_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.projects_id_seq OWNED BY public.projects.id;


--
-- Name: prompt_versions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.prompt_versions (
    id bigint NOT NULL,
    prompt_id bigint NOT NULL,
    version integer NOT NULL,
    template text NOT NULL,
    variables jsonb DEFAULT '[]'::jsonb NOT NULL,
    system_prompt text,
    change_notes text,
    created_by character varying(50),
    created_by_user_id bigint,
    parent_version_id bigint,
    usage_count integer DEFAULT 0 NOT NULL,
    avg_quality_score numeric(4,2),
    avg_iterations numeric(4,2),
    created_at timestamp(6) without time zone NOT NULL,
    retired_at timestamp(6) without time zone,
    review_status character varying(20),
    reviewed_by_user_id bigint,
    reviewed_at timestamp(6) without time zone,
    review_notes text
);

ALTER TABLE ONLY public.prompt_versions FORCE ROW LEVEL SECURITY;


--
-- Name: prompt_versions_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.prompt_versions_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: prompt_versions_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.prompt_versions_id_seq OWNED BY public.prompt_versions.id;


--
-- Name: prompts; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.prompts (
    id bigint NOT NULL,
    slug character varying(100) NOT NULL,
    name character varying(255) NOT NULL,
    description text,
    category character varying(50) NOT NULL,
    account_id bigint,
    project_id bigint,
    current_version_id bigint,
    active boolean DEFAULT true NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    requires_review boolean DEFAULT false NOT NULL,
    CONSTRAINT chk_prompts_scope_consistency CHECK (((project_id IS NULL) OR (account_id IS NOT NULL)))
);

ALTER TABLE ONLY public.prompts FORCE ROW LEVEL SECURITY;


--
-- Name: prompts_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.prompts_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: prompts_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.prompts_id_seq OWNED BY public.prompts.id;


--
-- Name: provider_api_keys; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.provider_api_keys (
    id bigint NOT NULL,
    user_id bigint NOT NULL,
    name character varying(100) NOT NULL,
    api_key text NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    api_service_type character varying(50) NOT NULL
);

ALTER TABLE ONLY public.provider_api_keys FORCE ROW LEVEL SECURITY;


--
-- Name: provider_api_keys_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.provider_api_keys_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: provider_api_keys_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.provider_api_keys_id_seq OWNED BY public.provider_api_keys.id;


--
-- Name: provider_states; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.provider_states (
    id bigint NOT NULL,
    user_id bigint NOT NULL,
    provider_name character varying(50) NOT NULL,
    rate_limited_until timestamp(6) without time zone,
    circuit_state character varying(20) DEFAULT 'closed'::character varying NOT NULL,
    failure_count integer DEFAULT 0 NOT NULL,
    circuit_opened_at timestamp(6) without time zone,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);

ALTER TABLE ONLY public.provider_states FORCE ROW LEVEL SECURITY;


--
-- Name: provider_states_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.provider_states_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: provider_states_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.provider_states_id_seq OWNED BY public.provider_states.id;


--
-- Name: providers; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.providers (
    id bigint NOT NULL,
    user_id bigint NOT NULL,
    provider_key character varying(50) NOT NULL,
    enabled_for_agent_runs boolean DEFAULT true NOT NULL,
    enabled_for_fallback boolean DEFAULT true NOT NULL,
    config jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    auth_type character varying(20) DEFAULT 'subscription'::character varying NOT NULL,
    name character varying(100) DEFAULT ''::character varying NOT NULL,
    fallback_role character varying(30) DEFAULT 'standard'::character varying NOT NULL,
    provider_api_key_id bigint,
    tier_model_ids jsonb DEFAULT '{}'::jsonb NOT NULL,
    agent_co_author_trailer text,
    complexity_thresholds jsonb DEFAULT '{"low_max": 3, "mid_max": 7}'::jsonb NOT NULL,
    weight integer DEFAULT 1 NOT NULL,
    CONSTRAINT providers_api_key_requires_key CHECK ((((auth_type)::text <> 'api_key'::text) OR (provider_api_key_id IS NOT NULL))),
    CONSTRAINT providers_subscription_invariants CHECK ((((auth_type)::text <> 'subscription'::text) OR ((provider_api_key_id IS NULL) AND ((fallback_role)::text = 'standard'::text)))),
    CONSTRAINT providers_weight_positive CHECK ((weight >= 1))
);

ALTER TABLE ONLY public.providers FORCE ROW LEVEL SECURITY;


--
-- Name: providers_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.providers_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: providers_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.providers_id_seq OWNED BY public.providers.id;


--
-- Name: quality_gate_events; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.quality_gate_events (
    id bigint NOT NULL,
    project_id bigint NOT NULL,
    quality_gate_threshold_id bigint NOT NULL,
    quality_metric_id bigint NOT NULL,
    event_type character varying(20) NOT NULL,
    score_value numeric(5,4) NOT NULL,
    threshold_value numeric(5,4) NOT NULL,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);

ALTER TABLE ONLY public.quality_gate_events FORCE ROW LEVEL SECURITY;


--
-- Name: quality_gate_events_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.quality_gate_events_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: quality_gate_events_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.quality_gate_events_id_seq OWNED BY public.quality_gate_events.id;


--
-- Name: quality_gate_thresholds; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.quality_gate_thresholds (
    id bigint NOT NULL,
    project_id bigint NOT NULL,
    metric_key character varying(50) NOT NULL,
    min_threshold numeric(5,4),
    max_threshold numeric(5,4),
    severity character varying(20) DEFAULT 'warning'::character varying NOT NULL,
    enabled boolean DEFAULT true NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);

ALTER TABLE ONLY public.quality_gate_thresholds FORCE ROW LEVEL SECURITY;


--
-- Name: quality_gate_thresholds_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.quality_gate_thresholds_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: quality_gate_thresholds_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.quality_gate_thresholds_id_seq OWNED BY public.quality_gate_thresholds.id;


--
-- Name: quality_metrics; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.quality_metrics (
    id bigint NOT NULL,
    agent_run_id bigint NOT NULL,
    prompt_version_id bigint,
    metric_type character varying(20) NOT NULL,
    scores jsonb DEFAULT '{}'::jsonb NOT NULL,
    composite_score numeric(5,4),
    feedback_source character varying(50),
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);

ALTER TABLE ONLY public.quality_metrics FORCE ROW LEVEL SECURITY;


--
-- Name: quality_metrics_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.quality_metrics_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: quality_metrics_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.quality_metrics_id_seq OWNED BY public.quality_metrics.id;


--
-- Name: quality_pause_events; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.quality_pause_events (
    id bigint NOT NULL,
    project_id bigint NOT NULL,
    agent_run_id bigint,
    event_type character varying(20) NOT NULL,
    composite_score numeric(5,4),
    threshold numeric(5,4),
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);

ALTER TABLE ONLY public.quality_pause_events FORCE ROW LEVEL SECURITY;


--
-- Name: quality_pause_events_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.quality_pause_events_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: quality_pause_events_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.quality_pause_events_id_seq OWNED BY public.quality_pause_events.id;


--
-- Name: quality_recovery_actions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.quality_recovery_actions (
    id bigint NOT NULL,
    project_id bigint NOT NULL,
    agent_run_id bigint,
    prompt_version_id bigint,
    action_type character varying(50) NOT NULL,
    status character varying(50) DEFAULT 'pending'::character varying NOT NULL,
    diagnosis jsonb DEFAULT '{}'::jsonb NOT NULL,
    parameters jsonb DEFAULT '{}'::jsonb NOT NULL,
    result jsonb DEFAULT '{}'::jsonb NOT NULL,
    quality_before numeric(5,4),
    quality_after numeric(5,4),
    executed_at timestamp(6) without time zone,
    evaluated_at timestamp(6) without time zone,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);

ALTER TABLE ONLY public.quality_recovery_actions FORCE ROW LEVEL SECURITY;


--
-- Name: quality_recovery_actions_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.quality_recovery_actions_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: quality_recovery_actions_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.quality_recovery_actions_id_seq OWNED BY public.quality_recovery_actions.id;


--
-- Name: quality_thresholds; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.quality_thresholds (
    id bigint NOT NULL,
    account_id bigint NOT NULL,
    project_id bigint,
    metric_type character varying(50) NOT NULL,
    goal_type character varying(50) NOT NULL,
    min_value numeric(5,4) NOT NULL,
    enabled boolean DEFAULT true NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);

ALTER TABLE ONLY public.quality_thresholds FORCE ROW LEVEL SECURITY;


--
-- Name: quality_thresholds_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.quality_thresholds_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: quality_thresholds_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.quality_thresholds_id_seq OWNED BY public.quality_thresholds.id;


--
-- Name: schema_migrations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.schema_migrations (
    version character varying NOT NULL
);


--
-- Name: service_container_metrics; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.service_container_metrics (
    id bigint NOT NULL,
    service_container_id bigint NOT NULL,
    container_id character varying(128) NOT NULL,
    cpu_percent double precision DEFAULT 0.0 NOT NULL,
    memory_bytes bigint DEFAULT 0 NOT NULL,
    memory_limit_bytes bigint DEFAULT 0 NOT NULL,
    memory_percent double precision DEFAULT 0.0 NOT NULL,
    pids_count integer,
    recorded_at timestamp(6) without time zone NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);

ALTER TABLE ONLY public.service_container_metrics FORCE ROW LEVEL SECURITY;


--
-- Name: service_container_metrics_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.service_container_metrics_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: service_container_metrics_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.service_container_metrics_id_seq OWNED BY public.service_container_metrics.id;


--
-- Name: service_containers; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.service_containers (
    id bigint NOT NULL,
    image character varying NOT NULL,
    name character varying NOT NULL,
    port integer NOT NULL,
    env jsonb DEFAULT '{}'::jsonb,
    docker_container_id character varying,
    status character varying DEFAULT 'stopped'::character varying NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    peak_cpu_percent double precision,
    peak_memory_bytes bigint,
    avg_cpu_percent double precision,
    avg_memory_bytes numeric(20,4),
    container_metrics_count integer DEFAULT 0 NOT NULL,
    account_id bigint NOT NULL
);

ALTER TABLE ONLY public.service_containers FORCE ROW LEVEL SECURITY;


--
-- Name: service_containers_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.service_containers_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: service_containers_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.service_containers_id_seq OWNED BY public.service_containers.id;


--
-- Name: style_guides; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.style_guides (
    id bigint NOT NULL,
    account_id bigint,
    project_id bigint,
    name character varying(255) NOT NULL,
    raw_content text NOT NULL,
    compressed_content text,
    compression_metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    active boolean DEFAULT true NOT NULL,
    language character varying(50),
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT chk_style_guides_scope_consistency CHECK (((project_id IS NULL) OR (account_id IS NOT NULL)))
);

ALTER TABLE ONLY public.style_guides FORCE ROW LEVEL SECURITY;


--
-- Name: style_guides_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.style_guides_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: style_guides_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.style_guides_id_seq OWNED BY public.style_guides.id;


--
-- Name: tenant_settings; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.tenant_settings (
    id bigint NOT NULL,
    account_id bigint NOT NULL,
    max_concurrent_runs integer DEFAULT 10 NOT NULL,
    max_projects integer DEFAULT 50 NOT NULL,
    max_users integer DEFAULT 25 NOT NULL,
    max_tokens_per_run integer DEFAULT 10000000 NOT NULL,
    max_monthly_cost_cents integer,
    allowed_provider_keys text[] DEFAULT '{}'::text[],
    features jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    provider_preferences jsonb DEFAULT '{}'::jsonb NOT NULL,
    default_budgets jsonb DEFAULT '{}'::jsonb NOT NULL,
    guardrails jsonb DEFAULT '{}'::jsonb NOT NULL,
    quality_thresholds jsonb DEFAULT '{}'::jsonb NOT NULL,
    agent_settings jsonb DEFAULT '{}'::jsonb NOT NULL,
    worker_settings jsonb DEFAULT '{}'::jsonb NOT NULL,
    self_repo_full_name character varying
);

ALTER TABLE ONLY public.tenant_settings FORCE ROW LEVEL SECURITY;


--
-- Name: tenant_settings_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.tenant_settings_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: tenant_settings_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.tenant_settings_id_seq OWNED BY public.tenant_settings.id;


--
-- Name: token_usages; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.token_usages (
    id bigint NOT NULL,
    agent_run_id bigint,
    llm_model character varying(100),
    request_type character varying(50) NOT NULL,
    input_tokens integer DEFAULT 0 NOT NULL,
    output_tokens integer DEFAULT 0 NOT NULL,
    cost_cents integer DEFAULT 0 NOT NULL,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    knowledge_run_id bigint,
    CONSTRAINT token_usages_exactly_one_run CHECK (((agent_run_id IS NOT NULL) <> (knowledge_run_id IS NOT NULL)))
);

ALTER TABLE ONLY public.token_usages FORCE ROW LEVEL SECURITY;


--
-- Name: token_usages_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.token_usages_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: token_usages_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.token_usages_id_seq OWNED BY public.token_usages.id;


--
-- Name: tracker_configurations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.tracker_configurations (
    id bigint NOT NULL,
    uuid uuid DEFAULT gen_random_uuid() NOT NULL,
    configurable_type character varying NOT NULL,
    configurable_id bigint NOT NULL,
    tracker_type character varying NOT NULL,
    base_url character varying,
    integration_credential_id bigint,
    project_mapping jsonb DEFAULT '{}'::jsonb,
    enabled boolean DEFAULT true NOT NULL,
    created_by_id bigint,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);

ALTER TABLE ONLY public.tracker_configurations FORCE ROW LEVEL SECURITY;


--
-- Name: tracker_configurations_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.tracker_configurations_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: tracker_configurations_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.tracker_configurations_id_seq OWNED BY public.tracker_configurations.id;


--
-- Name: user_settings; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.user_settings (
    id bigint NOT NULL,
    user_id bigint NOT NULL,
    default_poll_interval_seconds integer DEFAULT 60 NOT NULL,
    github_token_cache_ttl_minutes integer DEFAULT 60 NOT NULL,
    token_validation_stale_minutes integer DEFAULT 2 NOT NULL,
    agent_timeout_seconds integer DEFAULT 3600 NOT NULL,
    default_agent_provider character varying DEFAULT 'claude'::character varying NOT NULL,
    container_memory_bytes bigint DEFAULT '4294967296'::bigint NOT NULL,
    container_timeout_seconds integer DEFAULT 3600 NOT NULL,
    default_allowed_github_usernames jsonb DEFAULT '[]'::jsonb NOT NULL,
    default_branch character varying DEFAULT 'main'::character varying NOT NULL,
    default_project_active boolean DEFAULT true NOT NULL,
    circuit_breaker_failure_threshold integer DEFAULT 5 NOT NULL,
    circuit_breaker_timeout_seconds integer DEFAULT 300 NOT NULL,
    retry_max_attempts integer DEFAULT 3 NOT NULL,
    retry_base_delay double precision DEFAULT 1.0 NOT NULL,
    retry_max_delay double precision DEFAULT 60.0 NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    allowed_service_images jsonb DEFAULT '["postgres:16.13", "redis:7-alpine", "selenium/standalone-chromium:latest"]'::jsonb NOT NULL,
    fallback_providers jsonb DEFAULT '[]'::jsonb NOT NULL,
    fallback_enabled boolean DEFAULT false NOT NULL,
    max_concurrent_runs integer DEFAULT 2 NOT NULL,
    max_tokens_per_run integer DEFAULT 10000000 NOT NULL,
    issue_goal_timeout_seconds integer DEFAULT 600 NOT NULL,
    issue_goal_idle_timeout_seconds integer DEFAULT 120 NOT NULL,
    review_goal_idle_timeout_seconds integer DEFAULT 300 NOT NULL,
    git_clone_timeout_seconds integer DEFAULT 600 NOT NULL,
    git_push_timeout_seconds integer DEFAULT 60 NOT NULL,
    max_prompt_comments integer DEFAULT 20 NOT NULL,
    max_comment_length integer DEFAULT 2000 NOT NULL,
    style_guide_max_raw_bytes integer DEFAULT 100000 NOT NULL,
    style_guide_max_total_bytes integer DEFAULT 32000 NOT NULL,
    style_guide_max_raw_prompt_bytes integer DEFAULT 8000 NOT NULL,
    max_parallel_agents_per_project integer DEFAULT 3 NOT NULL,
    max_issues_per_page integer DEFAULT 50 NOT NULL,
    max_prs_per_page integer DEFAULT 50 NOT NULL,
    default_agent_providers_by_goal jsonb DEFAULT '{}'::jsonb NOT NULL,
    kb_embedding_provider character varying DEFAULT 'openai'::character varying NOT NULL,
    kb_embedding_fallback_providers jsonb DEFAULT '[]'::jsonb NOT NULL,
    kb_chat_provider character varying DEFAULT 'claude'::character varying NOT NULL,
    kb_chat_fallback_providers jsonb DEFAULT '[]'::jsonb NOT NULL,
    max_auto_pick_open_prs integer DEFAULT 1 NOT NULL,
    provider_selection_mode character varying(20) DEFAULT 'single'::character varying NOT NULL,
    provider_round_robin_state jsonb DEFAULT '{}'::jsonb NOT NULL,
    create_pr_idle_timeout_seconds integer DEFAULT 300 NOT NULL,
    theme_preference character varying DEFAULT 'system'::character varying NOT NULL,
    fair_queue_across_projects boolean DEFAULT true NOT NULL,
    CONSTRAINT chk_max_issues_per_page_bounds CHECK (((max_issues_per_page >= 5) AND (max_issues_per_page <= 200))),
    CONSTRAINT chk_max_prs_per_page_bounds CHECK (((max_prs_per_page >= 5) AND (max_prs_per_page <= 200))),
    CONSTRAINT chk_provider_selection_mode CHECK (((provider_selection_mode)::text = ANY (ARRAY[('single'::character varying)::text, ('round_robin'::character varying)::text, ('random'::character varying)::text])))
);

ALTER TABLE ONLY public.user_settings FORCE ROW LEVEL SECURITY;


--
-- Name: user_settings_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.user_settings_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: user_settings_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.user_settings_id_seq OWNED BY public.user_settings.id;


--
-- Name: users; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.users (
    id bigint NOT NULL,
    account_id bigint NOT NULL,
    name character varying,
    email character varying DEFAULT ''::character varying NOT NULL,
    encrypted_password character varying DEFAULT ''::character varying NOT NULL,
    reset_password_token character varying,
    reset_password_sent_at timestamp(6) without time zone,
    remember_created_at timestamp(6) without time zone,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);

ALTER TABLE ONLY public.users FORCE ROW LEVEL SECURITY;


--
-- Name: users_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.users_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: users_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.users_id_seq OWNED BY public.users.id;


--
-- Name: workflow_states; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.workflow_states (
    id bigint NOT NULL,
    temporal_workflow_id character varying NOT NULL,
    temporal_run_id character varying,
    project_id bigint,
    workflow_type character varying(100) NOT NULL,
    status character varying(50) DEFAULT 'running'::character varying NOT NULL,
    input_data jsonb,
    result_data jsonb,
    error_message text,
    started_at timestamp(6) without time zone,
    completed_at timestamp(6) without time zone,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    restart_reason text
);

ALTER TABLE ONLY public.workflow_states FORCE ROW LEVEL SECURITY;


--
-- Name: workflow_states_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.workflow_states_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: workflow_states_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.workflow_states_id_seq OWNED BY public.workflow_states.id;


--
-- Name: worktrees; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.worktrees (
    id bigint NOT NULL,
    project_id bigint NOT NULL,
    agent_run_id bigint,
    path character varying NOT NULL,
    branch_name character varying NOT NULL,
    base_commit character varying(40),
    status character varying(50) DEFAULT 'active'::character varying NOT NULL,
    pushed boolean DEFAULT false NOT NULL,
    cleaned_at timestamp(6) without time zone,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);

ALTER TABLE ONLY public.worktrees FORCE ROW LEVEL SECURITY;


--
-- Name: worktrees_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.worktrees_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: worktrees_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.worktrees_id_seq OWNED BY public.worktrees.id;


--
-- Name: ab_test_assignments id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ab_test_assignments ALTER COLUMN id SET DEFAULT nextval('public.ab_test_assignments_id_seq'::regclass);


--
-- Name: ab_test_variants id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ab_test_variants ALTER COLUMN id SET DEFAULT nextval('public.ab_test_variants_id_seq'::regclass);


--
-- Name: ab_tests id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ab_tests ALTER COLUMN id SET DEFAULT nextval('public.ab_tests_id_seq'::regclass);


--
-- Name: account_memberships id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.account_memberships ALTER COLUMN id SET DEFAULT nextval('public.account_memberships_id_seq'::regclass);


--
-- Name: accounts id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.accounts ALTER COLUMN id SET DEFAULT nextval('public.accounts_id_seq'::regclass);


--
-- Name: agent_coordination_signals id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.agent_coordination_signals ALTER COLUMN id SET DEFAULT nextval('public.agent_coordination_signals_id_seq'::regclass);


--
-- Name: agent_run_anomalies id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.agent_run_anomalies ALTER COLUMN id SET DEFAULT nextval('public.agent_run_anomalies_id_seq'::regclass);


--
-- Name: agent_run_logs id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.agent_run_logs ALTER COLUMN id SET DEFAULT nextval('public.agent_run_logs_id_seq'::regclass);


--
-- Name: agent_run_phases id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.agent_run_phases ALTER COLUMN id SET DEFAULT nextval('public.agent_run_phases_id_seq'::regclass);


--
-- Name: agent_runs id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.agent_runs ALTER COLUMN id SET DEFAULT nextval('public.agent_runs_id_seq'::regclass);


--
-- Name: billing_invoices id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.billing_invoices ALTER COLUMN id SET DEFAULT nextval('public.billing_invoices_id_seq'::regclass);


--
-- Name: billing_line_items id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.billing_line_items ALTER COLUMN id SET DEFAULT nextval('public.billing_line_items_id_seq'::regclass);


--
-- Name: billing_periods id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.billing_periods ALTER COLUMN id SET DEFAULT nextval('public.billing_periods_id_seq'::regclass);


--
-- Name: billing_plans id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.billing_plans ALTER COLUMN id SET DEFAULT nextval('public.billing_plans_id_seq'::regclass);


--
-- Name: chat_messages id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.chat_messages ALTER COLUMN id SET DEFAULT nextval('public.chat_messages_id_seq'::regclass);


--
-- Name: chat_session_projects id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.chat_session_projects ALTER COLUMN id SET DEFAULT nextval('public.chat_session_projects_id_seq'::regclass);


--
-- Name: chat_sessions id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.chat_sessions ALTER COLUMN id SET DEFAULT nextval('public.chat_sessions_id_seq'::regclass);


--
-- Name: collector_runs id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.collector_runs ALTER COLUMN id SET DEFAULT nextval('public.collector_runs_id_seq'::regclass);


--
-- Name: configuration_experiment_assignments id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.configuration_experiment_assignments ALTER COLUMN id SET DEFAULT nextval('public.configuration_experiment_assignments_id_seq'::regclass);


--
-- Name: configuration_experiment_variants id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.configuration_experiment_variants ALTER COLUMN id SET DEFAULT nextval('public.configuration_experiment_variants_id_seq'::regclass);


--
-- Name: configuration_experiments id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.configuration_experiments ALTER COLUMN id SET DEFAULT nextval('public.configuration_experiments_id_seq'::regclass);


--
-- Name: container_metrics id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.container_metrics ALTER COLUMN id SET DEFAULT nextval('public.container_metrics_id_seq'::regclass);


--
-- Name: container_pool_entries id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.container_pool_entries ALTER COLUMN id SET DEFAULT nextval('public.container_pool_entries_id_seq'::regclass);


--
-- Name: context_intake_responses id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.context_intake_responses ALTER COLUMN id SET DEFAULT nextval('public.context_intake_responses_id_seq'::regclass);


--
-- Name: context_intake_sessions id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.context_intake_sessions ALTER COLUMN id SET DEFAULT nextval('public.context_intake_sessions_id_seq'::regclass);


--
-- Name: cost_budgets id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.cost_budgets ALTER COLUMN id SET DEFAULT nextval('public.cost_budgets_id_seq'::regclass);


--
-- Name: decision_record_links id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.decision_record_links ALTER COLUMN id SET DEFAULT nextval('public.decision_record_links_id_seq'::regclass);


--
-- Name: decision_records id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.decision_records ALTER COLUMN id SET DEFAULT nextval('public.decision_records_id_seq'::regclass);


--
-- Name: flipper_features id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.flipper_features ALTER COLUMN id SET DEFAULT nextval('public.flipper_features_id_seq'::regclass);


--
-- Name: flipper_gates id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.flipper_gates ALTER COLUMN id SET DEFAULT nextval('public.flipper_gates_id_seq'::regclass);


--
-- Name: github_tokens id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.github_tokens ALTER COLUMN id SET DEFAULT nextval('public.github_tokens_id_seq'::regclass);


--
-- Name: integration_credentials id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.integration_credentials ALTER COLUMN id SET DEFAULT nextval('public.integration_credentials_id_seq'::regclass);


--
-- Name: issue_dependencies id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.issue_dependencies ALTER COLUMN id SET DEFAULT nextval('public.issue_dependencies_id_seq'::regclass);


--
-- Name: issues id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.issues ALTER COLUMN id SET DEFAULT nextval('public.issues_id_seq'::regclass);


--
-- Name: knowledge_artifacts id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_artifacts ALTER COLUMN id SET DEFAULT nextval('public.knowledge_artifacts_id_seq'::regclass);


--
-- Name: knowledge_audit_events id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_audit_events ALTER COLUMN id SET DEFAULT nextval('public.knowledge_audit_events_id_seq'::regclass);


--
-- Name: knowledge_links id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_links ALTER COLUMN id SET DEFAULT nextval('public.knowledge_links_id_seq'::regclass);


--
-- Name: knowledge_recommendations id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_recommendations ALTER COLUMN id SET DEFAULT nextval('public.knowledge_recommendations_id_seq'::regclass);


--
-- Name: knowledge_runs id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_runs ALTER COLUMN id SET DEFAULT nextval('public.knowledge_runs_id_seq'::regclass);


--
-- Name: knowledge_usage_stats id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_usage_stats ALTER COLUMN id SET DEFAULT nextval('public.knowledge_usage_stats_id_seq'::regclass);


--
-- Name: linear_tokens id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.linear_tokens ALTER COLUMN id SET DEFAULT nextval('public.linear_tokens_id_seq'::regclass);


--
-- Name: llm_models id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.llm_models ALTER COLUMN id SET DEFAULT nextval('public.llm_models_id_seq'::regclass);


--
-- Name: llm_output_metrics id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.llm_output_metrics ALTER COLUMN id SET DEFAULT nextval('public.llm_output_metrics_id_seq'::regclass);


--
-- Name: mcp_server_definitions id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.mcp_server_definitions ALTER COLUMN id SET DEFAULT nextval('public.mcp_server_definitions_id_seq'::regclass);


--
-- Name: model_selections id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.model_selections ALTER COLUMN id SET DEFAULT nextval('public.model_selections_id_seq'::regclass);


--
-- Name: notification_rule_states id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.notification_rule_states ALTER COLUMN id SET DEFAULT nextval('public.notification_rule_states_id_seq'::regclass);


--
-- Name: notifications id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.notifications ALTER COLUMN id SET DEFAULT nextval('public.notifications_id_seq'::regclass);


--
-- Name: onboarding_steps id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.onboarding_steps ALTER COLUMN id SET DEFAULT nextval('public.onboarding_steps_id_seq'::regclass);


--
-- Name: pr_templates id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pr_templates ALTER COLUMN id SET DEFAULT nextval('public.pr_templates_id_seq'::regclass);


--
-- Name: pre_commit_requirements id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pre_commit_requirements ALTER COLUMN id SET DEFAULT nextval('public.pre_commit_requirements_id_seq'::regclass);


--
-- Name: project_baselines id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.project_baselines ALTER COLUMN id SET DEFAULT nextval('public.project_baselines_id_seq'::regclass);


--
-- Name: project_mcp_servers id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.project_mcp_servers ALTER COLUMN id SET DEFAULT nextval('public.project_mcp_servers_id_seq'::regclass);


--
-- Name: project_memberships id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.project_memberships ALTER COLUMN id SET DEFAULT nextval('public.project_memberships_id_seq'::regclass);


--
-- Name: project_service_containers id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.project_service_containers ALTER COLUMN id SET DEFAULT nextval('public.project_service_containers_id_seq'::regclass);


--
-- Name: project_versions id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.project_versions ALTER COLUMN id SET DEFAULT nextval('public.project_versions_id_seq'::regclass);


--
-- Name: projects id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.projects ALTER COLUMN id SET DEFAULT nextval('public.projects_id_seq'::regclass);


--
-- Name: prompt_versions id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.prompt_versions ALTER COLUMN id SET DEFAULT nextval('public.prompt_versions_id_seq'::regclass);


--
-- Name: prompts id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.prompts ALTER COLUMN id SET DEFAULT nextval('public.prompts_id_seq'::regclass);


--
-- Name: provider_api_keys id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.provider_api_keys ALTER COLUMN id SET DEFAULT nextval('public.provider_api_keys_id_seq'::regclass);


--
-- Name: provider_states id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.provider_states ALTER COLUMN id SET DEFAULT nextval('public.provider_states_id_seq'::regclass);


--
-- Name: providers id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.providers ALTER COLUMN id SET DEFAULT nextval('public.providers_id_seq'::regclass);


--
-- Name: quality_gate_events id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.quality_gate_events ALTER COLUMN id SET DEFAULT nextval('public.quality_gate_events_id_seq'::regclass);


--
-- Name: quality_gate_thresholds id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.quality_gate_thresholds ALTER COLUMN id SET DEFAULT nextval('public.quality_gate_thresholds_id_seq'::regclass);


--
-- Name: quality_metrics id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.quality_metrics ALTER COLUMN id SET DEFAULT nextval('public.quality_metrics_id_seq'::regclass);


--
-- Name: quality_pause_events id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.quality_pause_events ALTER COLUMN id SET DEFAULT nextval('public.quality_pause_events_id_seq'::regclass);


--
-- Name: quality_recovery_actions id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.quality_recovery_actions ALTER COLUMN id SET DEFAULT nextval('public.quality_recovery_actions_id_seq'::regclass);


--
-- Name: quality_thresholds id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.quality_thresholds ALTER COLUMN id SET DEFAULT nextval('public.quality_thresholds_id_seq'::regclass);


--
-- Name: service_container_metrics id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.service_container_metrics ALTER COLUMN id SET DEFAULT nextval('public.service_container_metrics_id_seq'::regclass);


--
-- Name: service_containers id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.service_containers ALTER COLUMN id SET DEFAULT nextval('public.service_containers_id_seq'::regclass);


--
-- Name: style_guides id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.style_guides ALTER COLUMN id SET DEFAULT nextval('public.style_guides_id_seq'::regclass);


--
-- Name: tenant_settings id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tenant_settings ALTER COLUMN id SET DEFAULT nextval('public.tenant_settings_id_seq'::regclass);


--
-- Name: token_usages id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.token_usages ALTER COLUMN id SET DEFAULT nextval('public.token_usages_id_seq'::regclass);


--
-- Name: tracker_configurations id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tracker_configurations ALTER COLUMN id SET DEFAULT nextval('public.tracker_configurations_id_seq'::regclass);


--
-- Name: user_settings id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_settings ALTER COLUMN id SET DEFAULT nextval('public.user_settings_id_seq'::regclass);


--
-- Name: users id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.users ALTER COLUMN id SET DEFAULT nextval('public.users_id_seq'::regclass);


--
-- Name: workflow_states id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.workflow_states ALTER COLUMN id SET DEFAULT nextval('public.workflow_states_id_seq'::regclass);


--
-- Name: worktrees id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.worktrees ALTER COLUMN id SET DEFAULT nextval('public.worktrees_id_seq'::regclass);


--
-- Name: ab_test_assignments ab_test_assignments_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ab_test_assignments
    ADD CONSTRAINT ab_test_assignments_pkey PRIMARY KEY (id);


--
-- Name: ab_test_variants ab_test_variants_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ab_test_variants
    ADD CONSTRAINT ab_test_variants_pkey PRIMARY KEY (id);


--
-- Name: ab_tests ab_tests_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ab_tests
    ADD CONSTRAINT ab_tests_pkey PRIMARY KEY (id);


--
-- Name: account_memberships account_memberships_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.account_memberships
    ADD CONSTRAINT account_memberships_pkey PRIMARY KEY (id);


--
-- Name: accounts accounts_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.accounts
    ADD CONSTRAINT accounts_pkey PRIMARY KEY (id);


--
-- Name: agent_coordination_signals agent_coordination_signals_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.agent_coordination_signals
    ADD CONSTRAINT agent_coordination_signals_pkey PRIMARY KEY (id);


--
-- Name: agent_run_anomalies agent_run_anomalies_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.agent_run_anomalies
    ADD CONSTRAINT agent_run_anomalies_pkey PRIMARY KEY (id);


--
-- Name: agent_run_logs agent_run_logs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.agent_run_logs
    ADD CONSTRAINT agent_run_logs_pkey PRIMARY KEY (id);


--
-- Name: agent_run_phases agent_run_phases_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.agent_run_phases
    ADD CONSTRAINT agent_run_phases_pkey PRIMARY KEY (id);


--
-- Name: agent_runs agent_runs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.agent_runs
    ADD CONSTRAINT agent_runs_pkey PRIMARY KEY (id);


--
-- Name: ar_internal_metadata ar_internal_metadata_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ar_internal_metadata
    ADD CONSTRAINT ar_internal_metadata_pkey PRIMARY KEY (key);


--
-- Name: billing_invoices billing_invoices_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.billing_invoices
    ADD CONSTRAINT billing_invoices_pkey PRIMARY KEY (id);


--
-- Name: billing_line_items billing_line_items_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.billing_line_items
    ADD CONSTRAINT billing_line_items_pkey PRIMARY KEY (id);


--
-- Name: billing_periods billing_periods_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.billing_periods
    ADD CONSTRAINT billing_periods_pkey PRIMARY KEY (id);


--
-- Name: billing_plans billing_plans_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.billing_plans
    ADD CONSTRAINT billing_plans_pkey PRIMARY KEY (id);


--
-- Name: chat_messages chat_messages_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.chat_messages
    ADD CONSTRAINT chat_messages_pkey PRIMARY KEY (id);


--
-- Name: chat_session_projects chat_session_projects_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.chat_session_projects
    ADD CONSTRAINT chat_session_projects_pkey PRIMARY KEY (id);


--
-- Name: chat_sessions chat_sessions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.chat_sessions
    ADD CONSTRAINT chat_sessions_pkey PRIMARY KEY (id);


--
-- Name: collector_runs collector_runs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.collector_runs
    ADD CONSTRAINT collector_runs_pkey PRIMARY KEY (id);


--
-- Name: configuration_experiment_assignments configuration_experiment_assignments_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.configuration_experiment_assignments
    ADD CONSTRAINT configuration_experiment_assignments_pkey PRIMARY KEY (id);


--
-- Name: configuration_experiment_variants configuration_experiment_variants_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.configuration_experiment_variants
    ADD CONSTRAINT configuration_experiment_variants_pkey PRIMARY KEY (id);


--
-- Name: configuration_experiments configuration_experiments_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.configuration_experiments
    ADD CONSTRAINT configuration_experiments_pkey PRIMARY KEY (id);


--
-- Name: container_metrics container_metrics_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.container_metrics
    ADD CONSTRAINT container_metrics_pkey PRIMARY KEY (id);


--
-- Name: container_pool_entries container_pool_entries_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.container_pool_entries
    ADD CONSTRAINT container_pool_entries_pkey PRIMARY KEY (id);


--
-- Name: context_intake_responses context_intake_responses_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.context_intake_responses
    ADD CONSTRAINT context_intake_responses_pkey PRIMARY KEY (id);


--
-- Name: context_intake_sessions context_intake_sessions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.context_intake_sessions
    ADD CONSTRAINT context_intake_sessions_pkey PRIMARY KEY (id);


--
-- Name: cost_budgets cost_budgets_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.cost_budgets
    ADD CONSTRAINT cost_budgets_pkey PRIMARY KEY (id);


--
-- Name: decision_record_links decision_record_links_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.decision_record_links
    ADD CONSTRAINT decision_record_links_pkey PRIMARY KEY (id);


--
-- Name: decision_records decision_records_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.decision_records
    ADD CONSTRAINT decision_records_pkey PRIMARY KEY (id);


--
-- Name: flipper_features flipper_features_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.flipper_features
    ADD CONSTRAINT flipper_features_pkey PRIMARY KEY (id);


--
-- Name: flipper_gates flipper_gates_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.flipper_gates
    ADD CONSTRAINT flipper_gates_pkey PRIMARY KEY (id);


--
-- Name: github_tokens github_tokens_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.github_tokens
    ADD CONSTRAINT github_tokens_pkey PRIMARY KEY (id);


--
-- Name: good_job_batches good_job_batches_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.good_job_batches
    ADD CONSTRAINT good_job_batches_pkey PRIMARY KEY (id);


--
-- Name: good_job_executions good_job_executions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.good_job_executions
    ADD CONSTRAINT good_job_executions_pkey PRIMARY KEY (id);


--
-- Name: good_job_processes good_job_processes_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.good_job_processes
    ADD CONSTRAINT good_job_processes_pkey PRIMARY KEY (id);


--
-- Name: good_job_settings good_job_settings_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.good_job_settings
    ADD CONSTRAINT good_job_settings_pkey PRIMARY KEY (id);


--
-- Name: good_jobs good_jobs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.good_jobs
    ADD CONSTRAINT good_jobs_pkey PRIMARY KEY (id);


--
-- Name: integration_credentials integration_credentials_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.integration_credentials
    ADD CONSTRAINT integration_credentials_pkey PRIMARY KEY (id);


--
-- Name: issue_dependencies issue_dependencies_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.issue_dependencies
    ADD CONSTRAINT issue_dependencies_pkey PRIMARY KEY (id);


--
-- Name: issues issues_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.issues
    ADD CONSTRAINT issues_pkey PRIMARY KEY (id);


--
-- Name: knowledge_artifacts knowledge_artifacts_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_artifacts
    ADD CONSTRAINT knowledge_artifacts_pkey PRIMARY KEY (id);


--
-- Name: knowledge_audit_events knowledge_audit_events_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_audit_events
    ADD CONSTRAINT knowledge_audit_events_pkey PRIMARY KEY (id);


--
-- Name: knowledge_chunks knowledge_chunks_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_chunks
    ADD CONSTRAINT knowledge_chunks_pkey PRIMARY KEY (id);


--
-- Name: knowledge_links knowledge_links_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_links
    ADD CONSTRAINT knowledge_links_pkey PRIMARY KEY (id);


--
-- Name: knowledge_recommendations knowledge_recommendations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_recommendations
    ADD CONSTRAINT knowledge_recommendations_pkey PRIMARY KEY (id);


--
-- Name: knowledge_runs knowledge_runs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_runs
    ADD CONSTRAINT knowledge_runs_pkey PRIMARY KEY (id);


--
-- Name: knowledge_usage_stats knowledge_usage_stats_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_usage_stats
    ADD CONSTRAINT knowledge_usage_stats_pkey PRIMARY KEY (id);


--
-- Name: linear_tokens linear_tokens_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.linear_tokens
    ADD CONSTRAINT linear_tokens_pkey PRIMARY KEY (id);


--
-- Name: llm_models llm_models_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.llm_models
    ADD CONSTRAINT llm_models_pkey PRIMARY KEY (id);


--
-- Name: llm_output_metrics llm_output_metrics_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.llm_output_metrics
    ADD CONSTRAINT llm_output_metrics_pkey PRIMARY KEY (id);


--
-- Name: mcp_server_definitions mcp_server_definitions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.mcp_server_definitions
    ADD CONSTRAINT mcp_server_definitions_pkey PRIMARY KEY (id);


--
-- Name: model_selections model_selections_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.model_selections
    ADD CONSTRAINT model_selections_pkey PRIMARY KEY (id);


--
-- Name: notification_rule_states notification_rule_states_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.notification_rule_states
    ADD CONSTRAINT notification_rule_states_pkey PRIMARY KEY (id);


--
-- Name: notifications notifications_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.notifications
    ADD CONSTRAINT notifications_pkey PRIMARY KEY (id);


--
-- Name: onboarding_steps onboarding_steps_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.onboarding_steps
    ADD CONSTRAINT onboarding_steps_pkey PRIMARY KEY (id);


--
-- Name: pr_templates pr_templates_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pr_templates
    ADD CONSTRAINT pr_templates_pkey PRIMARY KEY (id);


--
-- Name: pre_commit_requirements pre_commit_requirements_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pre_commit_requirements
    ADD CONSTRAINT pre_commit_requirements_pkey PRIMARY KEY (id);


--
-- Name: project_baselines project_baselines_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.project_baselines
    ADD CONSTRAINT project_baselines_pkey PRIMARY KEY (id);


--
-- Name: project_mcp_servers project_mcp_servers_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.project_mcp_servers
    ADD CONSTRAINT project_mcp_servers_pkey PRIMARY KEY (id);


--
-- Name: project_memberships project_memberships_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.project_memberships
    ADD CONSTRAINT project_memberships_pkey PRIMARY KEY (id);


--
-- Name: project_service_containers project_service_containers_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.project_service_containers
    ADD CONSTRAINT project_service_containers_pkey PRIMARY KEY (id);


--
-- Name: project_versions project_versions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.project_versions
    ADD CONSTRAINT project_versions_pkey PRIMARY KEY (id);


--
-- Name: projects projects_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.projects
    ADD CONSTRAINT projects_pkey PRIMARY KEY (id);


--
-- Name: prompt_versions prompt_versions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.prompt_versions
    ADD CONSTRAINT prompt_versions_pkey PRIMARY KEY (id);


--
-- Name: prompts prompts_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.prompts
    ADD CONSTRAINT prompts_pkey PRIMARY KEY (id);


--
-- Name: provider_api_keys provider_api_keys_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.provider_api_keys
    ADD CONSTRAINT provider_api_keys_pkey PRIMARY KEY (id);


--
-- Name: provider_states provider_states_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.provider_states
    ADD CONSTRAINT provider_states_pkey PRIMARY KEY (id);


--
-- Name: providers providers_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.providers
    ADD CONSTRAINT providers_pkey PRIMARY KEY (id);


--
-- Name: quality_gate_events quality_gate_events_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.quality_gate_events
    ADD CONSTRAINT quality_gate_events_pkey PRIMARY KEY (id);


--
-- Name: quality_gate_thresholds quality_gate_thresholds_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.quality_gate_thresholds
    ADD CONSTRAINT quality_gate_thresholds_pkey PRIMARY KEY (id);


--
-- Name: quality_metrics quality_metrics_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.quality_metrics
    ADD CONSTRAINT quality_metrics_pkey PRIMARY KEY (id);


--
-- Name: quality_pause_events quality_pause_events_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.quality_pause_events
    ADD CONSTRAINT quality_pause_events_pkey PRIMARY KEY (id);


--
-- Name: quality_recovery_actions quality_recovery_actions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.quality_recovery_actions
    ADD CONSTRAINT quality_recovery_actions_pkey PRIMARY KEY (id);


--
-- Name: quality_thresholds quality_thresholds_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.quality_thresholds
    ADD CONSTRAINT quality_thresholds_pkey PRIMARY KEY (id);


--
-- Name: schema_migrations schema_migrations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.schema_migrations
    ADD CONSTRAINT schema_migrations_pkey PRIMARY KEY (version);


--
-- Name: service_container_metrics service_container_metrics_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.service_container_metrics
    ADD CONSTRAINT service_container_metrics_pkey PRIMARY KEY (id);


--
-- Name: service_containers service_containers_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.service_containers
    ADD CONSTRAINT service_containers_pkey PRIMARY KEY (id);


--
-- Name: style_guides style_guides_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.style_guides
    ADD CONSTRAINT style_guides_pkey PRIMARY KEY (id);


--
-- Name: tenant_settings tenant_settings_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tenant_settings
    ADD CONSTRAINT tenant_settings_pkey PRIMARY KEY (id);


--
-- Name: token_usages token_usages_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.token_usages
    ADD CONSTRAINT token_usages_pkey PRIMARY KEY (id);


--
-- Name: tracker_configurations tracker_configurations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tracker_configurations
    ADD CONSTRAINT tracker_configurations_pkey PRIMARY KEY (id);


--
-- Name: user_settings user_settings_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_settings
    ADD CONSTRAINT user_settings_pkey PRIMARY KEY (id);


--
-- Name: users users_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.users
    ADD CONSTRAINT users_pkey PRIMARY KEY (id);


--
-- Name: workflow_states workflow_states_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.workflow_states
    ADD CONSTRAINT workflow_states_pkey PRIMARY KEY (id);


--
-- Name: worktrees worktrees_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.worktrees
    ADD CONSTRAINT worktrees_pkey PRIMARY KEY (id);


--
-- Name: idx_agent_runs_project_created_at_desc; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_agent_runs_project_created_at_desc ON public.agent_runs USING btree (project_id, created_at DESC);


--
-- Name: idx_agent_runs_project_status_created_at_desc; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_agent_runs_project_status_created_at_desc ON public.agent_runs USING btree (project_id, status, created_at DESC);


--
-- Name: idx_agent_runs_unique_active_issue; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_agent_runs_unique_active_issue ON public.agent_runs USING btree (project_id, issue_id, goal) WHERE ((issue_id IS NOT NULL) AND ((status)::text = ANY (ARRAY[('queued'::character varying)::text, ('pending'::character varying)::text, ('running'::character varying)::text, ('paused'::character varying)::text])));


--
-- Name: idx_agent_runs_unique_active_pr; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_agent_runs_unique_active_pr ON public.agent_runs USING btree (project_id, source_pull_request_number, goal) WHERE ((source_pull_request_number IS NOT NULL) AND ((status)::text = ANY (ARRAY[('queued'::character varying)::text, ('pending'::character varying)::text, ('running'::character varying)::text, ('paused'::character varying)::text])));


--
-- Name: idx_context_intake_responses_session_question; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_context_intake_responses_session_question ON public.context_intake_responses USING btree (context_intake_session_id, question_key);


--
-- Name: idx_context_intake_responses_session_section_seq; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_context_intake_responses_session_section_seq ON public.context_intake_responses USING btree (context_intake_session_id, section, sequence);


--
-- Name: idx_coordination_signals_target_type; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_coordination_signals_target_type ON public.agent_coordination_signals USING btree (target_agent_run_id, signal_type);


--
-- Name: idx_coordination_signals_workflow_type; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_coordination_signals_workflow_type ON public.agent_coordination_signals USING btree (parent_workflow_id, signal_type);


--
-- Name: idx_issue_dependencies_unique; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_issue_dependencies_unique ON public.issue_dependencies USING btree (issue_id, depends_on_issue_id);


--
-- Name: idx_issue_deps_external_unique; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_issue_deps_external_unique ON public.issue_dependencies USING btree (issue_id, depends_on_owner, depends_on_repo, depends_on_number) WHERE (depends_on_owner IS NOT NULL);


--
-- Name: idx_issues_deployed_at_on_prs; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_issues_deployed_at_on_prs ON public.issues USING btree (deployed_at) WHERE (is_pull_request = true);


--
-- Name: idx_issues_on_project_source_state; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_issues_on_project_source_state ON public.issues USING btree (project_id, source, github_state);


--
-- Name: idx_issues_pr_review_phase; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_issues_pr_review_phase ON public.issues USING btree (project_id, pr_review_phase) WHERE ((is_pull_request = true) AND ((github_state)::text = 'open'::text));


--
-- Name: idx_issues_project_pr_phase_updated_at_desc; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_issues_project_pr_phase_updated_at_desc ON public.issues USING btree (project_id, is_pull_request, pr_review_phase, github_updated_at DESC);


--
-- Name: idx_knowledge_artifacts_active_unique; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_knowledge_artifacts_active_unique ON public.knowledge_artifacts USING btree (project_id, artifact_type, scope_path, identifier, collector_type) WHERE ((status)::text = 'active'::text);


--
-- Name: idx_knowledge_artifacts_on_project_type_scope_id_ctype_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_knowledge_artifacts_on_project_type_scope_id_ctype_status ON public.knowledge_artifacts USING btree (project_id, artifact_type, scope_path, identifier, collector_type, status);


--
-- Name: idx_knowledge_artifacts_project_status_identifier; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_knowledge_artifacts_project_status_identifier ON public.knowledge_artifacts USING btree (project_id, status, identifier);


--
-- Name: idx_knowledge_audit_events_on_created_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_knowledge_audit_events_on_created_at ON public.knowledge_audit_events USING brin (created_at);


--
-- Name: idx_knowledge_audit_events_on_project_created_at_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_knowledge_audit_events_on_project_created_at_id ON public.knowledge_audit_events USING btree (project_id, created_at DESC, id DESC);


--
-- Name: idx_knowledge_chunks_project_status_artifact_sequence; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_knowledge_chunks_project_status_artifact_sequence ON public.knowledge_chunks USING btree (project_id, status, knowledge_artifact_id, sequence);


--
-- Name: idx_knowledge_links_uniqueness; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_knowledge_links_uniqueness ON public.knowledge_links USING btree (source_chunk_id, target_chunk_id, link_type);


--
-- Name: idx_knowledge_usage_stats_unique; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_knowledge_usage_stats_unique ON public.knowledge_usage_stats USING btree (agent_run_id, artifact_type, context_type);


--
-- Name: idx_llm_output_metrics_project_type_time; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_llm_output_metrics_project_type_time ON public.llm_output_metrics USING btree (project_id, output_type, created_at);


--
-- Name: idx_llm_output_metrics_slug_version; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_llm_output_metrics_slug_version ON public.llm_output_metrics USING btree (prompt_slug, prompt_version_id);


--
-- Name: idx_llm_output_metrics_unique_source; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_llm_output_metrics_unique_source ON public.llm_output_metrics USING btree (project_id, output_type, source_type, source_id);


--
-- Name: idx_on_account_id_config_key_status_a42f39cd2a; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_account_id_config_key_status_a42f39cd2a ON public.configuration_experiments USING btree (account_id, config_key, status);


--
-- Name: idx_on_account_id_service_key_name_e4c03e1ea7; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_on_account_id_service_key_name_e4c03e1ea7 ON public.integration_credentials USING btree (account_id, service_key, name);


--
-- Name: idx_on_configuration_experiment_id_54cb3ed654; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_configuration_experiment_id_54cb3ed654 ON public.configuration_experiment_variants USING btree (configuration_experiment_id);


--
-- Name: idx_on_configuration_experiment_id_6532d1a5ed; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_configuration_experiment_id_6532d1a5ed ON public.configuration_experiment_assignments USING btree (configuration_experiment_id);


--
-- Name: idx_on_configuration_experiment_variant_id_9de5ff7df6; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_configuration_experiment_variant_id_9de5ff7df6 ON public.configuration_experiment_assignments USING btree (configuration_experiment_variant_id);


--
-- Name: idx_on_project_id_recommendation_type_333faaed2e; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_project_id_recommendation_type_333faaed2e ON public.knowledge_recommendations USING btree (project_id, recommendation_type);


--
-- Name: idx_on_project_id_status_warmed_at_d791387888; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_project_id_status_warmed_at_d791387888 ON public.container_pool_entries USING btree (project_id, status, warmed_at);


--
-- Name: idx_pr_templates_account_name_unique; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_pr_templates_account_name_unique ON public.pr_templates USING btree (account_id, name) WHERE ((project_id IS NULL) AND (user_id IS NULL));


--
-- Name: idx_pr_templates_account_position; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_pr_templates_account_position ON public.pr_templates USING btree (account_id, "position") WHERE ((project_id IS NULL) AND (user_id IS NULL));


--
-- Name: idx_pr_templates_project_name_unique; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_pr_templates_project_name_unique ON public.pr_templates USING btree (project_id, name) WHERE (project_id IS NOT NULL);


--
-- Name: idx_pr_templates_project_position; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_pr_templates_project_position ON public.pr_templates USING btree (project_id, "position") WHERE (project_id IS NOT NULL);


--
-- Name: idx_pr_templates_user_name_unique; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_pr_templates_user_name_unique ON public.pr_templates USING btree (user_id, name) WHERE ((user_id IS NOT NULL) AND (project_id IS NULL));


--
-- Name: idx_pr_templates_user_position; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_pr_templates_user_position ON public.pr_templates USING btree (user_id, "position") WHERE (user_id IS NOT NULL);


--
-- Name: idx_pre_commit_requirements_account_name_unique; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_pre_commit_requirements_account_name_unique ON public.pre_commit_requirements USING btree (account_id, name) WHERE ((project_id IS NULL) AND (user_id IS NULL));


--
-- Name: idx_pre_commit_requirements_account_position; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_pre_commit_requirements_account_position ON public.pre_commit_requirements USING btree (account_id, "position") WHERE ((project_id IS NULL) AND (user_id IS NULL));


--
-- Name: idx_pre_commit_requirements_project_name_unique; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_pre_commit_requirements_project_name_unique ON public.pre_commit_requirements USING btree (project_id, name) WHERE (project_id IS NOT NULL);


--
-- Name: idx_pre_commit_requirements_project_position; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_pre_commit_requirements_project_position ON public.pre_commit_requirements USING btree (project_id, "position") WHERE (project_id IS NOT NULL);


--
-- Name: idx_pre_commit_requirements_user_name_unique; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_pre_commit_requirements_user_name_unique ON public.pre_commit_requirements USING btree (user_id, name) WHERE ((user_id IS NOT NULL) AND (project_id IS NULL));


--
-- Name: idx_pre_commit_requirements_user_position; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_pre_commit_requirements_user_position ON public.pre_commit_requirements USING btree (user_id, "position") WHERE (user_id IS NOT NULL);


--
-- Name: idx_project_mcp_servers_unique; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_project_mcp_servers_unique ON public.project_mcp_servers USING btree (project_id, mcp_server_definition_id);


--
-- Name: idx_project_service_containers_unique; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_project_service_containers_unique ON public.project_service_containers USING btree (project_id, service_container_id);


--
-- Name: idx_providers_unique_api_key; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_providers_unique_api_key ON public.providers USING btree (user_id, provider_key, provider_api_key_id, name) WHERE ((auth_type)::text = 'api_key'::text);


--
-- Name: idx_providers_unique_subscription; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_providers_unique_subscription ON public.providers USING btree (user_id, provider_key) WHERE ((auth_type)::text = 'subscription'::text);


--
-- Name: idx_quality_gate_events_project_type_time; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_quality_gate_events_project_type_time ON public.quality_gate_events USING btree (project_id, event_type, created_at);


--
-- Name: idx_quality_gate_thresholds_project_enabled_metric; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_quality_gate_thresholds_project_enabled_metric ON public.quality_gate_thresholds USING btree (project_id, enabled, metric_key);


--
-- Name: idx_quality_metrics_prompt_recent_composite; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_quality_metrics_prompt_recent_composite ON public.quality_metrics USING btree (prompt_version_id, created_at DESC) WHERE (composite_score IS NOT NULL);


--
-- Name: idx_token_usages_agent_run_created_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_token_usages_agent_run_created_at ON public.token_usages USING btree (agent_run_id, created_at);


--
-- Name: idx_token_usages_knowledge_run_created_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_token_usages_knowledge_run_created_at ON public.token_usages USING btree (knowledge_run_id, created_at);


--
-- Name: idx_token_usages_request_type_created_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_token_usages_request_type_created_at ON public.token_usages USING btree (request_type, created_at);


--
-- Name: index_ab_test_assignments_on_ab_test_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_ab_test_assignments_on_ab_test_id ON public.ab_test_assignments USING btree (ab_test_id);


--
-- Name: index_ab_test_assignments_on_ab_test_variant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_ab_test_assignments_on_ab_test_variant_id ON public.ab_test_assignments USING btree (ab_test_variant_id);


--
-- Name: index_ab_test_assignments_on_agent_run_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_ab_test_assignments_on_agent_run_id ON public.ab_test_assignments USING btree (agent_run_id);


--
-- Name: index_ab_test_assignments_unique; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_ab_test_assignments_unique ON public.ab_test_assignments USING btree (ab_test_id, agent_run_id);


--
-- Name: index_ab_test_variants_on_ab_test_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_ab_test_variants_on_ab_test_id ON public.ab_test_variants USING btree (ab_test_id);


--
-- Name: index_ab_test_variants_on_control_per_test; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_ab_test_variants_on_control_per_test ON public.ab_test_variants USING btree (ab_test_id) WHERE (is_control = true);


--
-- Name: index_ab_test_variants_on_prompt_version_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_ab_test_variants_on_prompt_version_id ON public.ab_test_variants USING btree (prompt_version_id);


--
-- Name: index_ab_test_variants_on_test_and_control; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_ab_test_variants_on_test_and_control ON public.ab_test_variants USING btree (ab_test_id, is_control);


--
-- Name: index_ab_test_variants_on_test_and_prompt_version; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_ab_test_variants_on_test_and_prompt_version ON public.ab_test_variants USING btree (ab_test_id, prompt_version_id);


--
-- Name: index_ab_tests_on_control_version_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_ab_tests_on_control_version_id ON public.ab_tests USING btree (control_version_id);


--
-- Name: index_ab_tests_on_prompt_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_ab_tests_on_prompt_id ON public.ab_tests USING btree (prompt_id);


--
-- Name: index_ab_tests_on_prompt_id_and_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_ab_tests_on_prompt_id_and_status ON public.ab_tests USING btree (prompt_id, status);


--
-- Name: index_ab_tests_on_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_ab_tests_on_status ON public.ab_tests USING btree (status);


--
-- Name: index_ab_tests_on_winner_variant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_ab_tests_on_winner_variant_id ON public.ab_tests USING btree (winner_variant_id);


--
-- Name: index_ab_tests_one_running_per_prompt; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_ab_tests_one_running_per_prompt ON public.ab_tests USING btree (prompt_id) WHERE ((status)::text = 'running'::text);


--
-- Name: index_account_memberships_on_account_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_account_memberships_on_account_id ON public.account_memberships USING btree (account_id);


--
-- Name: index_account_memberships_on_account_id_and_role; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_account_memberships_on_account_id_and_role ON public.account_memberships USING btree (account_id, role);


--
-- Name: index_account_memberships_on_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_account_memberships_on_user_id ON public.account_memberships USING btree (user_id);


--
-- Name: index_account_memberships_on_user_id_and_account_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_account_memberships_on_user_id_and_account_id ON public.account_memberships USING btree (user_id, account_id);


--
-- Name: index_accounts_on_slug; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_accounts_on_slug ON public.accounts USING btree (slug);


--
-- Name: index_accounts_on_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_accounts_on_status ON public.accounts USING btree (status);


--
-- Name: index_agent_coordination_signals_on_parent_workflow_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_agent_coordination_signals_on_parent_workflow_id ON public.agent_coordination_signals USING btree (parent_workflow_id);


--
-- Name: index_agent_coordination_signals_on_source_agent_run_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_agent_coordination_signals_on_source_agent_run_id ON public.agent_coordination_signals USING btree (source_agent_run_id);


--
-- Name: index_agent_coordination_signals_on_target_agent_run_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_agent_coordination_signals_on_target_agent_run_id ON public.agent_coordination_signals USING btree (target_agent_run_id);


--
-- Name: index_agent_run_anomalies_on_agent_run_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_agent_run_anomalies_on_agent_run_id ON public.agent_run_anomalies USING btree (agent_run_id);


--
-- Name: index_agent_run_anomalies_on_agent_run_id_and_metric_name; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_agent_run_anomalies_on_agent_run_id_and_metric_name ON public.agent_run_anomalies USING btree (agent_run_id, metric_name);


--
-- Name: index_agent_run_anomalies_on_anomaly_type; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_agent_run_anomalies_on_anomaly_type ON public.agent_run_anomalies USING btree (anomaly_type);


--
-- Name: index_agent_run_anomalies_on_project_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_agent_run_anomalies_on_project_id ON public.agent_run_anomalies USING btree (project_id);


--
-- Name: index_agent_run_anomalies_on_project_id_and_created_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_agent_run_anomalies_on_project_id_and_created_at ON public.agent_run_anomalies USING btree (project_id, created_at);


--
-- Name: index_agent_run_logs_on_agent_run_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_agent_run_logs_on_agent_run_id ON public.agent_run_logs USING btree (agent_run_id);


--
-- Name: index_agent_run_logs_on_agent_run_id_and_log_type; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_agent_run_logs_on_agent_run_id_and_log_type ON public.agent_run_logs USING btree (agent_run_id, log_type);


--
-- Name: index_agent_run_logs_on_created_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_agent_run_logs_on_created_at ON public.agent_run_logs USING btree (created_at);


--
-- Name: index_agent_run_phases_on_agent_run_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_agent_run_phases_on_agent_run_id ON public.agent_run_phases USING btree (agent_run_id);


--
-- Name: index_agent_run_phases_on_agent_run_id_and_started_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_agent_run_phases_on_agent_run_id_and_started_at ON public.agent_run_phases USING btree (agent_run_id, started_at);


--
-- Name: index_agent_run_phases_on_phase_group_and_started_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_agent_run_phases_on_phase_group_and_started_at ON public.agent_run_phases USING btree (phase_group, started_at);


--
-- Name: index_agent_run_phases_on_phase_key_and_started_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_agent_run_phases_on_phase_key_and_started_at ON public.agent_run_phases USING btree (phase_key, started_at);


--
-- Name: index_agent_runs_on_created_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_agent_runs_on_created_at ON public.agent_runs USING btree (created_at);


--
-- Name: index_agent_runs_on_guardrail_violation_type; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_agent_runs_on_guardrail_violation_type ON public.agent_runs USING btree (guardrail_violation_type) WHERE (guardrail_violation_type IS NOT NULL);


--
-- Name: index_agent_runs_on_issue_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_agent_runs_on_issue_id ON public.agent_runs USING btree (issue_id);


--
-- Name: index_agent_runs_on_parent_workflow_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_agent_runs_on_parent_workflow_id ON public.agent_runs USING btree (parent_workflow_id);


--
-- Name: index_agent_runs_on_project_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_agent_runs_on_project_id ON public.agent_runs USING btree (project_id);


--
-- Name: index_agent_runs_on_project_id_and_goal; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_agent_runs_on_project_id_and_goal ON public.agent_runs USING btree (project_id, goal);


--
-- Name: index_agent_runs_on_project_id_and_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_agent_runs_on_project_id_and_status ON public.agent_runs USING btree (project_id, status);


--
-- Name: index_agent_runs_on_project_status_completed_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_agent_runs_on_project_status_completed_at ON public.agent_runs USING btree (project_id, status, completed_at);


--
-- Name: index_agent_runs_on_prompt_version_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_agent_runs_on_prompt_version_id ON public.agent_runs USING btree (prompt_version_id);


--
-- Name: index_agent_runs_on_provider_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_agent_runs_on_provider_id ON public.agent_runs USING btree (provider_id);


--
-- Name: index_agent_runs_on_proxy_token; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_agent_runs_on_proxy_token ON public.agent_runs USING btree (proxy_token);


--
-- Name: index_agent_runs_on_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_agent_runs_on_status ON public.agent_runs USING btree (status);


--
-- Name: index_agent_runs_on_temporal_workflow_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_agent_runs_on_temporal_workflow_id ON public.agent_runs USING btree (temporal_workflow_id);


--
-- Name: index_billing_invoices_on_account_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_billing_invoices_on_account_id ON public.billing_invoices USING btree (account_id);


--
-- Name: index_billing_invoices_on_account_id_and_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_billing_invoices_on_account_id_and_status ON public.billing_invoices USING btree (account_id, status);


--
-- Name: index_billing_invoices_on_billing_period_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_billing_invoices_on_billing_period_id ON public.billing_invoices USING btree (billing_period_id);


--
-- Name: index_billing_invoices_on_external_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_billing_invoices_on_external_id ON public.billing_invoices USING btree (external_id) WHERE (external_id IS NOT NULL);


--
-- Name: index_billing_line_items_on_billing_invoice_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_billing_line_items_on_billing_invoice_id ON public.billing_line_items USING btree (billing_invoice_id);


--
-- Name: index_billing_line_items_on_line_item_type; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_billing_line_items_on_line_item_type ON public.billing_line_items USING btree (line_item_type);


--
-- Name: index_billing_periods_on_account_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_billing_periods_on_account_id ON public.billing_periods USING btree (account_id);


--
-- Name: index_billing_periods_on_account_id_and_starts_at_and_ends_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_billing_periods_on_account_id_and_starts_at_and_ends_at ON public.billing_periods USING btree (account_id, starts_at, ends_at);


--
-- Name: index_billing_periods_on_account_id_and_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_billing_periods_on_account_id_and_status ON public.billing_periods USING btree (account_id, status);


--
-- Name: index_billing_periods_on_billing_plan_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_billing_periods_on_billing_plan_id ON public.billing_periods USING btree (billing_plan_id);


--
-- Name: index_billing_plans_on_account_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_billing_plans_on_account_id ON public.billing_plans USING btree (account_id);


--
-- Name: index_billing_plans_on_account_id_and_active; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_billing_plans_on_account_id_and_active ON public.billing_plans USING btree (account_id, active);


--
-- Name: index_chat_messages_on_chat_session_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_chat_messages_on_chat_session_id ON public.chat_messages USING btree (chat_session_id);


--
-- Name: index_chat_messages_on_chat_session_id_and_created_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_chat_messages_on_chat_session_id_and_created_at ON public.chat_messages USING btree (chat_session_id, created_at);


--
-- Name: index_chat_messages_on_external_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_chat_messages_on_external_id ON public.chat_messages USING btree (external_id);


--
-- Name: index_chat_messages_on_role; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_chat_messages_on_role ON public.chat_messages USING btree (role);


--
-- Name: index_chat_session_projects_on_chat_session_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_chat_session_projects_on_chat_session_id ON public.chat_session_projects USING btree (chat_session_id);


--
-- Name: index_chat_session_projects_on_chat_session_id_and_project_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_chat_session_projects_on_chat_session_id_and_project_id ON public.chat_session_projects USING btree (chat_session_id, project_id);


--
-- Name: index_chat_session_projects_on_project_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_chat_session_projects_on_project_id ON public.chat_session_projects USING btree (project_id);


--
-- Name: index_chat_sessions_on_account_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_chat_sessions_on_account_id ON public.chat_sessions USING btree (account_id);


--
-- Name: index_chat_sessions_on_created_by_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_chat_sessions_on_created_by_id ON public.chat_sessions USING btree (created_by_id);


--
-- Name: index_chat_sessions_on_external_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_chat_sessions_on_external_id ON public.chat_sessions USING btree (external_id);


--
-- Name: index_chat_sessions_on_idle_timeout_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_chat_sessions_on_idle_timeout_at ON public.chat_sessions USING btree (idle_timeout_at);


--
-- Name: index_chat_sessions_on_project_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_chat_sessions_on_project_id ON public.chat_sessions USING btree (project_id);


--
-- Name: index_chat_sessions_on_provider_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_chat_sessions_on_provider_id ON public.chat_sessions USING btree (provider_id);


--
-- Name: index_chat_sessions_on_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_chat_sessions_on_status ON public.chat_sessions USING btree (status);


--
-- Name: index_collector_runs_on_project_version_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_collector_runs_on_project_version_id ON public.collector_runs USING btree (project_version_id);


--
-- Name: index_collector_runs_on_project_version_id_and_collector_type; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_collector_runs_on_project_version_id_and_collector_type ON public.collector_runs USING btree (project_version_id, collector_type);


--
-- Name: index_collector_runs_on_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_collector_runs_on_status ON public.collector_runs USING btree (status);


--
-- Name: index_config_experiment_assignments_unique; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_config_experiment_assignments_unique ON public.configuration_experiment_assignments USING btree (configuration_experiment_id, agent_run_id);


--
-- Name: index_config_experiment_variants_on_experiment_and_control; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_config_experiment_variants_on_experiment_and_control ON public.configuration_experiment_variants USING btree (configuration_experiment_id, is_control);


--
-- Name: index_config_experiment_variants_one_control; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_config_experiment_variants_one_control ON public.configuration_experiment_variants USING btree (configuration_experiment_id) WHERE (is_control = true);


--
-- Name: index_config_experiments_one_running_per_account_key; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_config_experiments_one_running_per_account_key ON public.configuration_experiments USING btree (account_id, config_key) WHERE (((status)::text = 'running'::text) AND (account_id IS NOT NULL));


--
-- Name: index_configuration_experiment_assignments_on_agent_run_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_configuration_experiment_assignments_on_agent_run_id ON public.configuration_experiment_assignments USING btree (agent_run_id);


--
-- Name: index_configuration_experiments_on_account_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_configuration_experiments_on_account_id ON public.configuration_experiments USING btree (account_id);


--
-- Name: index_configuration_experiments_on_winner_variant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_configuration_experiments_on_winner_variant_id ON public.configuration_experiments USING btree (winner_variant_id);


--
-- Name: index_container_metrics_on_container_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_container_metrics_on_container_id ON public.container_metrics USING btree (container_id);


--
-- Name: index_container_metrics_on_recorded_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_container_metrics_on_recorded_at ON public.container_metrics USING btree (recorded_at);


--
-- Name: index_container_metrics_on_run_and_recorded; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_container_metrics_on_run_and_recorded ON public.container_metrics USING btree (agent_run_id, recorded_at);


--
-- Name: index_container_pool_entries_on_agent_run_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_container_pool_entries_on_agent_run_id ON public.container_pool_entries USING btree (agent_run_id);


--
-- Name: index_container_pool_entries_on_container_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_container_pool_entries_on_container_id ON public.container_pool_entries USING btree (container_id) WHERE (container_id IS NOT NULL);


--
-- Name: index_container_pool_entries_on_project_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_container_pool_entries_on_project_id ON public.container_pool_entries USING btree (project_id);


--
-- Name: index_container_pool_entries_on_workspace_volume; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_container_pool_entries_on_workspace_volume ON public.container_pool_entries USING btree (workspace_volume);


--
-- Name: index_context_intake_responses_on_context_intake_session_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_context_intake_responses_on_context_intake_session_id ON public.context_intake_responses USING btree (context_intake_session_id);


--
-- Name: index_context_intake_responses_on_parent_response_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_context_intake_responses_on_parent_response_id ON public.context_intake_responses USING btree (parent_response_id);


--
-- Name: index_context_intake_sessions_on_project_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_context_intake_sessions_on_project_id ON public.context_intake_sessions USING btree (project_id);


--
-- Name: index_context_intake_sessions_on_project_id_and_created_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_context_intake_sessions_on_project_id_and_created_at ON public.context_intake_sessions USING btree (project_id, created_at DESC);


--
-- Name: index_context_intake_sessions_on_project_id_and_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_context_intake_sessions_on_project_id_and_status ON public.context_intake_sessions USING btree (project_id, status);


--
-- Name: index_context_intake_sessions_on_started_by_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_context_intake_sessions_on_started_by_id ON public.context_intake_sessions USING btree (started_by_id);


--
-- Name: index_cost_budgets_on_project_id_and_budget_type; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_cost_budgets_on_project_id_and_budget_type ON public.cost_budgets USING btree (project_id, budget_type);


--
-- Name: index_decision_record_links_on_decision_record_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_decision_record_links_on_decision_record_id ON public.decision_record_links USING btree (decision_record_id);


--
-- Name: index_decision_record_links_on_linkable_type_and_linkable_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_decision_record_links_on_linkable_type_and_linkable_id ON public.decision_record_links USING btree (linkable_type, linkable_id);


--
-- Name: index_decision_record_links_on_record_and_linkable_and_type; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_decision_record_links_on_record_and_linkable_and_type ON public.decision_record_links USING btree (decision_record_id, linkable_type, linkable_id, link_type);


--
-- Name: index_decision_records_on_agent_run_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_decision_records_on_agent_run_id ON public.decision_records USING btree (agent_run_id) WHERE (agent_run_id IS NOT NULL);


--
-- Name: index_decision_records_on_issue_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_decision_records_on_issue_id ON public.decision_records USING btree (issue_id);


--
-- Name: index_decision_records_on_project_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_decision_records_on_project_id ON public.decision_records USING btree (project_id);


--
-- Name: index_decision_records_on_project_id_and_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_decision_records_on_project_id_and_status ON public.decision_records USING btree (project_id, status);


--
-- Name: index_decision_records_on_superseded_by_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_decision_records_on_superseded_by_id ON public.decision_records USING btree (superseded_by_id);


--
-- Name: index_decision_records_on_tags; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_decision_records_on_tags ON public.decision_records USING gin (tags);


--
-- Name: index_flipper_features_on_key; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_flipper_features_on_key ON public.flipper_features USING btree (key);


--
-- Name: index_flipper_gates_on_feature_key_and_key_and_value; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_flipper_gates_on_feature_key_and_key_and_value ON public.flipper_gates USING btree (feature_key, key, value);


--
-- Name: index_github_tokens_on_account_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_github_tokens_on_account_id ON public.github_tokens USING btree (account_id);


--
-- Name: index_github_tokens_on_account_id_and_name; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_github_tokens_on_account_id_and_name ON public.github_tokens USING btree (account_id, name);


--
-- Name: index_github_tokens_on_created_by_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_github_tokens_on_created_by_id ON public.github_tokens USING btree (created_by_id);


--
-- Name: index_github_tokens_on_revoked_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_github_tokens_on_revoked_at ON public.github_tokens USING btree (revoked_at);


--
-- Name: index_github_tokens_on_validation_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_github_tokens_on_validation_status ON public.github_tokens USING btree (validation_status);


--
-- Name: index_global_config_experiments_one_running_per_key; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_global_config_experiments_one_running_per_key ON public.configuration_experiments USING btree (config_key) WHERE (((status)::text = 'running'::text) AND (account_id IS NULL));


--
-- Name: index_good_job_executions_on_active_job_id_and_created_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_good_job_executions_on_active_job_id_and_created_at ON public.good_job_executions USING btree (active_job_id, created_at);


--
-- Name: index_good_job_executions_on_process_id_and_created_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_good_job_executions_on_process_id_and_created_at ON public.good_job_executions USING btree (process_id, created_at);


--
-- Name: index_good_job_jobs_for_candidate_lookup; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_good_job_jobs_for_candidate_lookup ON public.good_jobs USING btree (priority, created_at) WHERE (finished_at IS NULL);


--
-- Name: index_good_job_settings_on_key; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_good_job_settings_on_key ON public.good_job_settings USING btree (key);


--
-- Name: index_good_jobs_jobs_on_finished_at_only; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_good_jobs_jobs_on_finished_at_only ON public.good_jobs USING btree (finished_at) WHERE (finished_at IS NOT NULL);


--
-- Name: index_good_jobs_jobs_on_priority_created_at_when_unfinished; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_good_jobs_jobs_on_priority_created_at_when_unfinished ON public.good_jobs USING btree (priority DESC NULLS LAST, created_at) WHERE (finished_at IS NULL);


--
-- Name: index_good_jobs_on_active_job_id_and_created_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_good_jobs_on_active_job_id_and_created_at ON public.good_jobs USING btree (active_job_id, created_at);


--
-- Name: index_good_jobs_on_batch_callback_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_good_jobs_on_batch_callback_id ON public.good_jobs USING btree (batch_callback_id) WHERE (batch_callback_id IS NOT NULL);


--
-- Name: index_good_jobs_on_batch_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_good_jobs_on_batch_id ON public.good_jobs USING btree (batch_id) WHERE (batch_id IS NOT NULL);


--
-- Name: index_good_jobs_on_concurrency_key_and_created_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_good_jobs_on_concurrency_key_and_created_at ON public.good_jobs USING btree (concurrency_key, created_at);


--
-- Name: index_good_jobs_on_concurrency_key_when_unfinished; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_good_jobs_on_concurrency_key_when_unfinished ON public.good_jobs USING btree (concurrency_key) WHERE (finished_at IS NULL);


--
-- Name: index_good_jobs_on_cron_key_and_created_at_cond; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_good_jobs_on_cron_key_and_created_at_cond ON public.good_jobs USING btree (cron_key, created_at) WHERE (cron_key IS NOT NULL);


--
-- Name: index_good_jobs_on_cron_key_and_cron_at_cond; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_good_jobs_on_cron_key_and_cron_at_cond ON public.good_jobs USING btree (cron_key, cron_at) WHERE (cron_key IS NOT NULL);


--
-- Name: index_good_jobs_on_job_class; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_good_jobs_on_job_class ON public.good_jobs USING btree (job_class);


--
-- Name: index_good_jobs_on_labels; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_good_jobs_on_labels ON public.good_jobs USING gin (labels) WHERE (labels IS NOT NULL);


--
-- Name: index_good_jobs_on_locked_by_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_good_jobs_on_locked_by_id ON public.good_jobs USING btree (locked_by_id) WHERE (locked_by_id IS NOT NULL);


--
-- Name: index_good_jobs_on_priority_scheduled_at_unfinished_unlocked; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_good_jobs_on_priority_scheduled_at_unfinished_unlocked ON public.good_jobs USING btree (priority, scheduled_at) WHERE ((finished_at IS NULL) AND (locked_by_id IS NULL));


--
-- Name: index_good_jobs_on_queue_name_and_scheduled_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_good_jobs_on_queue_name_and_scheduled_at ON public.good_jobs USING btree (queue_name, scheduled_at) WHERE (finished_at IS NULL);


--
-- Name: index_good_jobs_on_scheduled_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_good_jobs_on_scheduled_at ON public.good_jobs USING btree (scheduled_at) WHERE (finished_at IS NULL);


--
-- Name: index_integration_credentials_on_account_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_integration_credentials_on_account_id ON public.integration_credentials USING btree (account_id);


--
-- Name: index_integration_credentials_on_account_id_and_category; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_integration_credentials_on_account_id_and_category ON public.integration_credentials USING btree (account_id, category);


--
-- Name: index_integration_credentials_on_account_id_and_revoked_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_integration_credentials_on_account_id_and_revoked_at ON public.integration_credentials USING btree (account_id, revoked_at);


--
-- Name: index_integration_credentials_on_account_id_and_service_key; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_integration_credentials_on_account_id_and_service_key ON public.integration_credentials USING btree (account_id, service_key);


--
-- Name: index_integration_credentials_on_created_by_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_integration_credentials_on_created_by_id ON public.integration_credentials USING btree (created_by_id);


--
-- Name: index_issue_dependencies_on_depends_on_issue_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_issue_dependencies_on_depends_on_issue_id ON public.issue_dependencies USING btree (depends_on_issue_id);


--
-- Name: index_issue_dependencies_on_issue_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_issue_dependencies_on_issue_id ON public.issue_dependencies USING btree (issue_id);


--
-- Name: index_issues_on_github_creator_login; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_issues_on_github_creator_login ON public.issues USING btree (github_creator_login);


--
-- Name: index_issues_on_labels_gin_open_issues; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_issues_on_labels_gin_open_issues ON public.issues USING gin (labels) WHERE ((is_pull_request = false) AND ((github_state)::text = 'open'::text));


--
-- Name: index_issues_on_labels_gin_open_prs; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_issues_on_labels_gin_open_prs ON public.issues USING gin (labels) WHERE ((is_pull_request = true) AND ((github_state)::text = 'open'::text));


--
-- Name: index_issues_on_parent_issue_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_issues_on_parent_issue_id ON public.issues USING btree (parent_issue_id);


--
-- Name: index_issues_on_project_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_issues_on_project_id ON public.issues USING btree (project_id);


--
-- Name: index_issues_on_project_id_and_github_issue_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_issues_on_project_id_and_github_issue_id ON public.issues USING btree (project_id, github_issue_id);


--
-- Name: index_issues_on_project_id_and_github_number; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_issues_on_project_id_and_github_number ON public.issues USING btree (project_id, github_number);


--
-- Name: index_issues_on_project_id_and_paid_state; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_issues_on_project_id_and_paid_state ON public.issues USING btree (project_id, paid_state);


--
-- Name: index_issues_on_relationships_parsed_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_issues_on_relationships_parsed_at ON public.issues USING btree (relationships_parsed_at);


--
-- Name: index_issues_on_source; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_issues_on_source ON public.issues USING btree (source);


--
-- Name: index_knowledge_artifacts_on_collector_run_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_knowledge_artifacts_on_collector_run_id ON public.knowledge_artifacts USING btree (collector_run_id);


--
-- Name: index_knowledge_artifacts_on_collector_run_id_and_content_hash; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_knowledge_artifacts_on_collector_run_id_and_content_hash ON public.knowledge_artifacts USING btree (collector_run_id, content_hash);


--
-- Name: index_knowledge_artifacts_on_identifier_trgm; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_knowledge_artifacts_on_identifier_trgm ON public.knowledge_artifacts USING gin (identifier public.gin_trgm_ops);


--
-- Name: index_knowledge_artifacts_on_project_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_knowledge_artifacts_on_project_id ON public.knowledge_artifacts USING btree (project_id);


--
-- Name: index_knowledge_artifacts_on_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_knowledge_artifacts_on_status ON public.knowledge_artifacts USING btree (status);


--
-- Name: index_knowledge_audit_events_on_event_type; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_knowledge_audit_events_on_event_type ON public.knowledge_audit_events USING btree (event_type);


--
-- Name: index_knowledge_audit_events_on_project_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_knowledge_audit_events_on_project_id ON public.knowledge_audit_events USING btree (project_id);


--
-- Name: index_knowledge_audit_events_on_target_type_and_target_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_knowledge_audit_events_on_target_type_and_target_id ON public.knowledge_audit_events USING btree (target_type, target_id);


--
-- Name: index_knowledge_chunks_on_content_hash; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_knowledge_chunks_on_content_hash ON public.knowledge_chunks USING btree (content_hash);


--
-- Name: index_knowledge_chunks_on_content_tsvector; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_knowledge_chunks_on_content_tsvector ON public.knowledge_chunks USING gin (content_tsvector);


--
-- Name: index_knowledge_chunks_on_knowledge_artifact_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_knowledge_chunks_on_knowledge_artifact_id ON public.knowledge_chunks USING btree (knowledge_artifact_id);


--
-- Name: index_knowledge_chunks_on_project_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_knowledge_chunks_on_project_id ON public.knowledge_chunks USING btree (project_id);


--
-- Name: index_knowledge_chunks_on_project_id_and_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_knowledge_chunks_on_project_id_and_status ON public.knowledge_chunks USING btree (project_id, status);


--
-- Name: index_knowledge_links_on_link_type; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_knowledge_links_on_link_type ON public.knowledge_links USING btree (link_type);


--
-- Name: index_knowledge_links_on_target_chunk_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_knowledge_links_on_target_chunk_id ON public.knowledge_links USING btree (target_chunk_id);


--
-- Name: index_knowledge_recommendations_on_project_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_knowledge_recommendations_on_project_id ON public.knowledge_recommendations USING btree (project_id);


--
-- Name: index_knowledge_recommendations_on_project_id_and_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_knowledge_recommendations_on_project_id_and_status ON public.knowledge_recommendations USING btree (project_id, status);


--
-- Name: index_knowledge_runs_on_project_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_knowledge_runs_on_project_id ON public.knowledge_runs USING btree (project_id);


--
-- Name: index_knowledge_runs_on_project_id_and_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_knowledge_runs_on_project_id_and_status ON public.knowledge_runs USING btree (project_id, status);


--
-- Name: index_knowledge_runs_on_proxy_token; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_knowledge_runs_on_proxy_token ON public.knowledge_runs USING btree (proxy_token);


--
-- Name: index_knowledge_usage_stats_on_agent_run_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_knowledge_usage_stats_on_agent_run_id ON public.knowledge_usage_stats USING btree (agent_run_id);


--
-- Name: index_knowledge_usage_stats_on_artifact_type_and_goal; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_knowledge_usage_stats_on_artifact_type_and_goal ON public.knowledge_usage_stats USING btree (artifact_type, goal);


--
-- Name: index_knowledge_usage_stats_on_project_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_knowledge_usage_stats_on_project_id ON public.knowledge_usage_stats USING btree (project_id);


--
-- Name: index_knowledge_usage_stats_on_project_id_and_created_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_knowledge_usage_stats_on_project_id_and_created_at ON public.knowledge_usage_stats USING btree (project_id, created_at);


--
-- Name: index_linear_tokens_on_account_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_linear_tokens_on_account_id ON public.linear_tokens USING btree (account_id);


--
-- Name: index_linear_tokens_on_account_id_and_name; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_linear_tokens_on_account_id_and_name ON public.linear_tokens USING btree (account_id, name);


--
-- Name: index_linear_tokens_on_created_by_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_linear_tokens_on_created_by_id ON public.linear_tokens USING btree (created_by_id);


--
-- Name: index_linear_tokens_on_revoked_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_linear_tokens_on_revoked_at ON public.linear_tokens USING btree (revoked_at);


--
-- Name: index_llm_models_on_active; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_llm_models_on_active ON public.llm_models USING btree (active);


--
-- Name: index_llm_models_on_category; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_llm_models_on_category ON public.llm_models USING btree (category);


--
-- Name: index_llm_models_on_model_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_llm_models_on_model_id ON public.llm_models USING btree (model_id);


--
-- Name: index_llm_models_on_provider; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_llm_models_on_provider ON public.llm_models USING btree (provider);


--
-- Name: index_llm_models_on_provider_and_active; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_llm_models_on_provider_and_active ON public.llm_models USING btree (provider, active);


--
-- Name: index_llm_models_on_tier; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_llm_models_on_tier ON public.llm_models USING btree (tier);


--
-- Name: index_llm_output_metrics_on_account_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_llm_output_metrics_on_account_id ON public.llm_output_metrics USING btree (account_id);


--
-- Name: index_llm_output_metrics_on_output_type; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_llm_output_metrics_on_output_type ON public.llm_output_metrics USING btree (output_type);


--
-- Name: index_llm_output_metrics_on_project_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_llm_output_metrics_on_project_id ON public.llm_output_metrics USING btree (project_id);


--
-- Name: index_llm_output_metrics_on_prompt_version_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_llm_output_metrics_on_prompt_version_id ON public.llm_output_metrics USING btree (prompt_version_id);


--
-- Name: index_llm_output_metrics_on_source_type_and_source_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_llm_output_metrics_on_source_type_and_source_id ON public.llm_output_metrics USING btree (source_type, source_id);


--
-- Name: index_mcp_server_definitions_on_account_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_mcp_server_definitions_on_account_id ON public.mcp_server_definitions USING btree (account_id);


--
-- Name: index_mcp_server_definitions_on_account_id_and_enabled; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_mcp_server_definitions_on_account_id_and_enabled ON public.mcp_server_definitions USING btree (account_id, enabled);


--
-- Name: index_mcp_server_definitions_on_account_id_and_name; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_mcp_server_definitions_on_account_id_and_name ON public.mcp_server_definitions USING btree (account_id, name);


--
-- Name: index_model_selections_on_agent_run_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_model_selections_on_agent_run_id ON public.model_selections USING btree (agent_run_id);


--
-- Name: index_model_selections_on_llm_model_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_model_selections_on_llm_model_id ON public.model_selections USING btree (llm_model_id);


--
-- Name: index_model_selections_on_selector_type; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_model_selections_on_selector_type ON public.model_selections USING btree (selector_type);


--
-- Name: index_model_selections_on_tier; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_model_selections_on_tier ON public.model_selections USING btree (tier);


--
-- Name: index_notification_rule_states_on_account_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_notification_rule_states_on_account_id ON public.notification_rule_states USING btree (account_id);


--
-- Name: index_notification_rule_states_on_dedup; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_notification_rule_states_on_dedup ON public.notification_rule_states USING btree (account_id, source, subject_type, subject_id);


--
-- Name: index_notification_rule_states_on_subject; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_notification_rule_states_on_subject ON public.notification_rule_states USING btree (subject_type, subject_id);


--
-- Name: index_notifications_on_badge; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_notifications_on_badge ON public.notifications USING btree (account_id, nav_section, read_at);


--
-- Name: index_notifications_on_dedup; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_notifications_on_dedup ON public.notifications USING btree (account_id, user_id, source, subject_type, subject_id);


--
-- Name: index_notifications_on_dedup_account_wide; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_notifications_on_dedup_account_wide ON public.notifications USING btree (account_id, source, subject_type, subject_id) WHERE (user_id IS NULL);


--
-- Name: index_notifications_on_subject; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_notifications_on_subject ON public.notifications USING btree (subject_type, subject_id);


--
-- Name: index_notifications_on_unread; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_notifications_on_unread ON public.notifications USING btree (account_id, read_at, dismissed_at);


--
-- Name: index_notifications_on_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_notifications_on_user_id ON public.notifications USING btree (user_id);


--
-- Name: index_onboarding_steps_on_account_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_onboarding_steps_on_account_id ON public.onboarding_steps USING btree (account_id);


--
-- Name: index_onboarding_steps_on_account_id_and_position; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_onboarding_steps_on_account_id_and_position ON public.onboarding_steps USING btree (account_id, "position");


--
-- Name: index_onboarding_steps_on_account_id_and_step; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_onboarding_steps_on_account_id_and_step ON public.onboarding_steps USING btree (account_id, step);


--
-- Name: index_pr_templates_on_account_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_pr_templates_on_account_id ON public.pr_templates USING btree (account_id);


--
-- Name: index_pr_templates_on_project_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_pr_templates_on_project_id ON public.pr_templates USING btree (project_id);


--
-- Name: index_pr_templates_on_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_pr_templates_on_user_id ON public.pr_templates USING btree (user_id);


--
-- Name: index_pre_commit_requirements_on_account_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_pre_commit_requirements_on_account_id ON public.pre_commit_requirements USING btree (account_id);


--
-- Name: index_pre_commit_requirements_on_project_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_pre_commit_requirements_on_project_id ON public.pre_commit_requirements USING btree (project_id);


--
-- Name: index_pre_commit_requirements_on_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_pre_commit_requirements_on_user_id ON public.pre_commit_requirements USING btree (user_id);


--
-- Name: index_project_baselines_on_project_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_project_baselines_on_project_id ON public.project_baselines USING btree (project_id);


--
-- Name: index_project_baselines_on_project_id_and_metric_name; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_project_baselines_on_project_id_and_metric_name ON public.project_baselines USING btree (project_id, metric_name);


--
-- Name: index_project_mcp_servers_on_mcp_server_definition_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_project_mcp_servers_on_mcp_server_definition_id ON public.project_mcp_servers USING btree (mcp_server_definition_id);


--
-- Name: index_project_mcp_servers_on_project_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_project_mcp_servers_on_project_id ON public.project_mcp_servers USING btree (project_id);


--
-- Name: index_project_memberships_on_project_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_project_memberships_on_project_id ON public.project_memberships USING btree (project_id);


--
-- Name: index_project_memberships_on_project_id_and_role; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_project_memberships_on_project_id_and_role ON public.project_memberships USING btree (project_id, role);


--
-- Name: index_project_memberships_on_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_project_memberships_on_user_id ON public.project_memberships USING btree (user_id);


--
-- Name: index_project_memberships_on_user_id_and_project_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_project_memberships_on_user_id_and_project_id ON public.project_memberships USING btree (user_id, project_id);


--
-- Name: index_project_service_containers_on_project_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_project_service_containers_on_project_id ON public.project_service_containers USING btree (project_id);


--
-- Name: index_project_service_containers_on_service_container_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_project_service_containers_on_service_container_id ON public.project_service_containers USING btree (service_container_id);


--
-- Name: index_project_versions_on_project_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_project_versions_on_project_id ON public.project_versions USING btree (project_id);


--
-- Name: index_project_versions_on_project_id_and_commit_sha; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_project_versions_on_project_id_and_commit_sha ON public.project_versions USING btree (project_id, commit_sha);


--
-- Name: index_project_versions_on_project_id_and_committed_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_project_versions_on_project_id_and_committed_at ON public.project_versions USING btree (project_id, committed_at DESC);


--
-- Name: index_projects_on_account_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_projects_on_account_id ON public.projects USING btree (account_id);


--
-- Name: index_projects_on_account_id_and_active; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_projects_on_account_id_and_active ON public.projects USING btree (account_id, active);


--
-- Name: index_projects_on_account_id_and_github_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_projects_on_account_id_and_github_id ON public.projects USING btree (account_id, github_id);


--
-- Name: index_projects_on_account_id_and_last_agent_run_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_projects_on_account_id_and_last_agent_run_at ON public.projects USING btree (account_id, last_agent_run_at);


--
-- Name: index_projects_on_account_id_and_last_github_activity_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_projects_on_account_id_and_last_github_activity_at ON public.projects USING btree (account_id, last_github_activity_at);


--
-- Name: index_projects_on_created_by_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_projects_on_created_by_id ON public.projects USING btree (created_by_id);


--
-- Name: index_projects_on_github_token_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_projects_on_github_token_id ON public.projects USING btree (github_token_id);


--
-- Name: index_projects_on_owner_and_repo; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_projects_on_owner_and_repo ON public.projects USING btree (owner, repo);


--
-- Name: index_projects_on_quality_paused_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_projects_on_quality_paused_at ON public.projects USING btree (quality_paused_at) WHERE (quality_paused_at IS NOT NULL);


--
-- Name: index_projects_on_scheduler_paused_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_projects_on_scheduler_paused_at ON public.projects USING btree (scheduler_paused_at) WHERE (scheduler_paused_at IS NOT NULL);


--
-- Name: index_prompt_versions_on_created_by_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_prompt_versions_on_created_by_user_id ON public.prompt_versions USING btree (created_by_user_id);


--
-- Name: index_prompt_versions_on_parent_version_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_prompt_versions_on_parent_version_id ON public.prompt_versions USING btree (parent_version_id);


--
-- Name: index_prompt_versions_on_prompt_and_review_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_prompt_versions_on_prompt_and_review_status ON public.prompt_versions USING btree (prompt_id, review_status) WHERE (review_status IS NOT NULL);


--
-- Name: index_prompt_versions_on_prompt_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_prompt_versions_on_prompt_id ON public.prompt_versions USING btree (prompt_id);


--
-- Name: index_prompt_versions_on_prompt_id_and_version; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_prompt_versions_on_prompt_id_and_version ON public.prompt_versions USING btree (prompt_id, version);


--
-- Name: index_prompt_versions_on_retired_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_prompt_versions_on_retired_at ON public.prompt_versions USING btree (retired_at);


--
-- Name: index_prompt_versions_on_reviewed_by_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_prompt_versions_on_reviewed_by_user_id ON public.prompt_versions USING btree (reviewed_by_user_id);


--
-- Name: index_prompts_on_account_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_prompts_on_account_id ON public.prompts USING btree (account_id);


--
-- Name: index_prompts_on_active; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_prompts_on_active ON public.prompts USING btree (active);


--
-- Name: index_prompts_on_category; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_prompts_on_category ON public.prompts USING btree (category);


--
-- Name: index_prompts_on_current_version_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_prompts_on_current_version_id ON public.prompts USING btree (current_version_id);


--
-- Name: index_prompts_on_project_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_prompts_on_project_id ON public.prompts USING btree (project_id);


--
-- Name: index_prompts_on_slug_account; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_prompts_on_slug_account ON public.prompts USING btree (slug, account_id) WHERE ((account_id IS NOT NULL) AND (project_id IS NULL));


--
-- Name: index_prompts_on_slug_global; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_prompts_on_slug_global ON public.prompts USING btree (slug) WHERE ((account_id IS NULL) AND (project_id IS NULL));


--
-- Name: index_prompts_on_slug_project; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_prompts_on_slug_project ON public.prompts USING btree (slug, project_id) WHERE (project_id IS NOT NULL);


--
-- Name: index_provider_api_keys_on_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_provider_api_keys_on_user_id ON public.provider_api_keys USING btree (user_id);


--
-- Name: index_provider_api_keys_on_user_id_and_api_service_type; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_provider_api_keys_on_user_id_and_api_service_type ON public.provider_api_keys USING btree (user_id, api_service_type);


--
-- Name: index_provider_api_keys_on_user_id_and_name; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_provider_api_keys_on_user_id_and_name ON public.provider_api_keys USING btree (user_id, name);


--
-- Name: index_provider_states_on_user_id_and_provider_name; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_provider_states_on_user_id_and_provider_name ON public.provider_states USING btree (user_id, provider_name);


--
-- Name: index_providers_on_auth_type; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_providers_on_auth_type ON public.providers USING btree (auth_type);


--
-- Name: index_providers_on_provider_api_key_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_providers_on_provider_api_key_id ON public.providers USING btree (provider_api_key_id);


--
-- Name: index_providers_on_tier_model_ids; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_providers_on_tier_model_ids ON public.providers USING gin (tier_model_ids);


--
-- Name: index_providers_on_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_providers_on_user_id ON public.providers USING btree (user_id);


--
-- Name: index_quality_gate_events_on_project_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_quality_gate_events_on_project_id ON public.quality_gate_events USING btree (project_id);


--
-- Name: index_quality_gate_events_on_quality_gate_threshold_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_quality_gate_events_on_quality_gate_threshold_id ON public.quality_gate_events USING btree (quality_gate_threshold_id);


--
-- Name: index_quality_gate_events_on_quality_metric_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_quality_gate_events_on_quality_metric_id ON public.quality_gate_events USING btree (quality_metric_id);


--
-- Name: index_quality_gate_thresholds_on_project_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_quality_gate_thresholds_on_project_id ON public.quality_gate_thresholds USING btree (project_id);


--
-- Name: index_quality_gate_thresholds_on_project_id_and_metric_key; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_quality_gate_thresholds_on_project_id_and_metric_key ON public.quality_gate_thresholds USING btree (project_id, metric_key);


--
-- Name: index_quality_metrics_on_agent_run_and_type; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_quality_metrics_on_agent_run_and_type ON public.quality_metrics USING btree (agent_run_id, metric_type);


--
-- Name: index_quality_metrics_on_agent_run_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_quality_metrics_on_agent_run_id ON public.quality_metrics USING btree (agent_run_id);


--
-- Name: index_quality_metrics_on_composite_score; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_quality_metrics_on_composite_score ON public.quality_metrics USING btree (composite_score);


--
-- Name: index_quality_metrics_on_created_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_quality_metrics_on_created_at ON public.quality_metrics USING btree (created_at);


--
-- Name: index_quality_metrics_on_metric_type; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_quality_metrics_on_metric_type ON public.quality_metrics USING btree (metric_type);


--
-- Name: index_quality_metrics_on_prompt_version_and_created_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_quality_metrics_on_prompt_version_and_created_at ON public.quality_metrics USING btree (prompt_version_id, created_at);


--
-- Name: index_quality_metrics_on_prompt_version_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_quality_metrics_on_prompt_version_id ON public.quality_metrics USING btree (prompt_version_id);


--
-- Name: index_quality_pause_events_on_agent_run_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_quality_pause_events_on_agent_run_id ON public.quality_pause_events USING btree (agent_run_id);


--
-- Name: index_quality_pause_events_on_project_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_quality_pause_events_on_project_id ON public.quality_pause_events USING btree (project_id);


--
-- Name: index_quality_pause_events_on_project_id_and_created_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_quality_pause_events_on_project_id_and_created_at ON public.quality_pause_events USING btree (project_id, created_at);


--
-- Name: index_quality_recovery_actions_on_action_type; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_quality_recovery_actions_on_action_type ON public.quality_recovery_actions USING btree (action_type);


--
-- Name: index_quality_recovery_actions_on_agent_run_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_quality_recovery_actions_on_agent_run_id ON public.quality_recovery_actions USING btree (agent_run_id);


--
-- Name: index_quality_recovery_actions_on_project_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_quality_recovery_actions_on_project_id ON public.quality_recovery_actions USING btree (project_id);


--
-- Name: index_quality_recovery_actions_on_project_id_and_created_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_quality_recovery_actions_on_project_id_and_created_at ON public.quality_recovery_actions USING btree (project_id, created_at);


--
-- Name: index_quality_recovery_actions_on_prompt_version_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_quality_recovery_actions_on_prompt_version_id ON public.quality_recovery_actions USING btree (prompt_version_id);


--
-- Name: index_quality_recovery_actions_on_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_quality_recovery_actions_on_status ON public.quality_recovery_actions USING btree (status);


--
-- Name: index_quality_thresholds_on_account_defaults; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_quality_thresholds_on_account_defaults ON public.quality_thresholds USING btree (account_id, metric_type, goal_type) WHERE (project_id IS NULL);


--
-- Name: index_quality_thresholds_on_account_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_quality_thresholds_on_account_id ON public.quality_thresholds USING btree (account_id);


--
-- Name: index_quality_thresholds_on_project_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_quality_thresholds_on_project_id ON public.quality_thresholds USING btree (project_id);


--
-- Name: index_quality_thresholds_on_project_overrides; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_quality_thresholds_on_project_overrides ON public.quality_thresholds USING btree (project_id, metric_type, goal_type) WHERE (project_id IS NOT NULL);


--
-- Name: index_service_container_metrics_on_container_and_recorded; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_service_container_metrics_on_container_and_recorded ON public.service_container_metrics USING btree (service_container_id, recorded_at);


--
-- Name: index_service_container_metrics_on_container_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_service_container_metrics_on_container_id ON public.service_container_metrics USING btree (container_id);


--
-- Name: index_service_container_metrics_on_recorded_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_service_container_metrics_on_recorded_at ON public.service_container_metrics USING btree (recorded_at);


--
-- Name: index_service_container_metrics_on_service_container_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_service_container_metrics_on_service_container_id ON public.service_container_metrics USING btree (service_container_id);


--
-- Name: index_service_containers_on_account_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_service_containers_on_account_id ON public.service_containers USING btree (account_id);


--
-- Name: index_service_containers_on_account_id_and_name; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_service_containers_on_account_id_and_name ON public.service_containers USING btree (account_id, name);


--
-- Name: index_style_guides_on_account_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_style_guides_on_account_id ON public.style_guides USING btree (account_id);


--
-- Name: index_style_guides_on_active; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_style_guides_on_active ON public.style_guides USING btree (active);


--
-- Name: index_style_guides_on_language; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_style_guides_on_language ON public.style_guides USING btree (language);


--
-- Name: index_style_guides_on_name_account; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_style_guides_on_name_account ON public.style_guides USING btree (name, account_id) WHERE ((account_id IS NOT NULL) AND (project_id IS NULL));


--
-- Name: index_style_guides_on_name_global; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_style_guides_on_name_global ON public.style_guides USING btree (name) WHERE ((account_id IS NULL) AND (project_id IS NULL));


--
-- Name: index_style_guides_on_name_project; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_style_guides_on_name_project ON public.style_guides USING btree (name, project_id) WHERE (project_id IS NOT NULL);


--
-- Name: index_style_guides_on_project_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_style_guides_on_project_id ON public.style_guides USING btree (project_id);


--
-- Name: index_tenant_settings_on_account_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_tenant_settings_on_account_id ON public.tenant_settings USING btree (account_id);


--
-- Name: index_token_usages_on_agent_run_id_and_request_type; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_token_usages_on_agent_run_id_and_request_type ON public.token_usages USING btree (agent_run_id, request_type);


--
-- Name: index_token_usages_on_created_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_token_usages_on_created_at ON public.token_usages USING btree (created_at);


--
-- Name: index_token_usages_on_knowledge_run_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_token_usages_on_knowledge_run_id ON public.token_usages USING btree (knowledge_run_id);


--
-- Name: index_token_usages_on_llm_model; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_token_usages_on_llm_model ON public.token_usages USING btree (llm_model);


--
-- Name: index_token_usages_on_request_type; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_token_usages_on_request_type ON public.token_usages USING btree (request_type);


--
-- Name: index_tracker_configurations_on_configurable; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_tracker_configurations_on_configurable ON public.tracker_configurations USING btree (configurable_type, configurable_id);


--
-- Name: index_tracker_configurations_on_created_by_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_tracker_configurations_on_created_by_id ON public.tracker_configurations USING btree (created_by_id);


--
-- Name: index_tracker_configurations_on_integration_credential_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_tracker_configurations_on_integration_credential_id ON public.tracker_configurations USING btree (integration_credential_id);


--
-- Name: index_tracker_configurations_on_tracker_type; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_tracker_configurations_on_tracker_type ON public.tracker_configurations USING btree (tracker_type);


--
-- Name: index_tracker_configurations_on_uuid; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_tracker_configurations_on_uuid ON public.tracker_configurations USING btree (uuid);


--
-- Name: index_user_settings_on_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_user_settings_on_user_id ON public.user_settings USING btree (user_id);


--
-- Name: index_users_on_account_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_users_on_account_id ON public.users USING btree (account_id);


--
-- Name: index_users_on_email; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_users_on_email ON public.users USING btree (email);


--
-- Name: index_users_on_reset_password_token; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_users_on_reset_password_token ON public.users USING btree (reset_password_token);


--
-- Name: index_workflow_states_on_project_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_workflow_states_on_project_id ON public.workflow_states USING btree (project_id);


--
-- Name: index_workflow_states_on_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_workflow_states_on_status ON public.workflow_states USING btree (status);


--
-- Name: index_workflow_states_on_temporal_workflow_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_workflow_states_on_temporal_workflow_id ON public.workflow_states USING btree (temporal_workflow_id);


--
-- Name: index_worktrees_on_agent_run_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_worktrees_on_agent_run_id ON public.worktrees USING btree (agent_run_id);


--
-- Name: index_worktrees_on_project_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_worktrees_on_project_id ON public.worktrees USING btree (project_id);


--
-- Name: index_worktrees_on_project_id_and_branch_name; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_worktrees_on_project_id_and_branch_name ON public.worktrees USING btree (project_id, branch_name);


--
-- Name: index_worktrees_on_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_worktrees_on_status ON public.worktrees USING btree (status);


--
-- Name: knowledge_chunks knowledge_chunks_tsvector_update; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER knowledge_chunks_tsvector_update BEFORE INSERT OR UPDATE OF content ON public.knowledge_chunks FOR EACH ROW EXECUTE FUNCTION tsvector_update_trigger('content_tsvector', 'pg_catalog.english', 'content');


--
-- Name: token_usages fk_rails_007cf0910c; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.token_usages
    ADD CONSTRAINT fk_rails_007cf0910c FOREIGN KEY (agent_run_id) REFERENCES public.agent_runs(id) ON DELETE CASCADE;


--
-- Name: decision_records fk_rails_01f33ed76e; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.decision_records
    ADD CONSTRAINT fk_rails_01f33ed76e FOREIGN KEY (project_id) REFERENCES public.projects(id) ON DELETE CASCADE;


--
-- Name: project_mcp_servers fk_rails_04e723b430; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.project_mcp_servers
    ADD CONSTRAINT fk_rails_04e723b430 FOREIGN KEY (project_id) REFERENCES public.projects(id);


--
-- Name: tracker_configurations fk_rails_05e081e1b2; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tracker_configurations
    ADD CONSTRAINT fk_rails_05e081e1b2 FOREIGN KEY (integration_credential_id) REFERENCES public.integration_credentials(id);


--
-- Name: agent_runs fk_rails_0779afb693; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.agent_runs
    ADD CONSTRAINT fk_rails_0779afb693 FOREIGN KEY (prompt_version_id) REFERENCES public.prompt_versions(id) ON DELETE SET NULL;


--
-- Name: agent_runs fk_rails_0af97c5d68; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.agent_runs
    ADD CONSTRAINT fk_rails_0af97c5d68 FOREIGN KEY (provider_id) REFERENCES public.providers(id) ON DELETE SET NULL;


--
-- Name: agent_coordination_signals fk_rails_0e200247b7; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.agent_coordination_signals
    ADD CONSTRAINT fk_rails_0e200247b7 FOREIGN KEY (source_agent_run_id) REFERENCES public.agent_runs(id);


--
-- Name: integration_credentials fk_rails_0fa2dfe3bd; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.integration_credentials
    ADD CONSTRAINT fk_rails_0fa2dfe3bd FOREIGN KEY (created_by_id) REFERENCES public.users(id);


--
-- Name: project_baselines fk_rails_125cb2c17e; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.project_baselines
    ADD CONSTRAINT fk_rails_125cb2c17e FOREIGN KEY (project_id) REFERENCES public.projects(id);


--
-- Name: agent_coordination_signals fk_rails_1349bc307d; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.agent_coordination_signals
    ADD CONSTRAINT fk_rails_1349bc307d FOREIGN KEY (target_agent_run_id) REFERENCES public.agent_runs(id);


--
-- Name: providers fk_rails_173128f3bd; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.providers
    ADD CONSTRAINT fk_rails_173128f3bd FOREIGN KEY (provider_api_key_id) REFERENCES public.provider_api_keys(id) ON DELETE RESTRICT;


--
-- Name: project_memberships fk_rails_18b611e244; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.project_memberships
    ADD CONSTRAINT fk_rails_18b611e244 FOREIGN KEY (project_id) REFERENCES public.projects(id);


--
-- Name: tracker_configurations fk_rails_1ba0f7ea23; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tracker_configurations
    ADD CONSTRAINT fk_rails_1ba0f7ea23 FOREIGN KEY (created_by_id) REFERENCES public.users(id);


--
-- Name: notifications fk_rails_1c0a19e3ee; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.notifications
    ADD CONSTRAINT fk_rails_1c0a19e3ee FOREIGN KEY (account_id) REFERENCES public.accounts(id);


--
-- Name: notification_rule_states fk_rails_1d0b19e4ff; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.notification_rule_states
    ADD CONSTRAINT fk_rails_1d0b19e4ff FOREIGN KEY (account_id) REFERENCES public.accounts(id);


--
-- Name: prompt_versions fk_rails_1eb0a8163a; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.prompt_versions
    ADD CONSTRAINT fk_rails_1eb0a8163a FOREIGN KEY (created_by_user_id) REFERENCES public.users(id) ON DELETE SET NULL;


--
-- Name: service_container_metrics fk_rails_20eb9b57f8; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.service_container_metrics
    ADD CONSTRAINT fk_rails_20eb9b57f8 FOREIGN KEY (service_container_id) REFERENCES public.service_containers(id) ON DELETE CASCADE;


--
-- Name: project_service_containers fk_rails_22486be20b; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.project_service_containers
    ADD CONSTRAINT fk_rails_22486be20b FOREIGN KEY (service_container_id) REFERENCES public.service_containers(id) ON DELETE CASCADE;


--
-- Name: pre_commit_requirements fk_rails_23004001c3; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pre_commit_requirements
    ADD CONSTRAINT fk_rails_23004001c3 FOREIGN KEY (project_id) REFERENCES public.projects(id) ON DELETE CASCADE;


--
-- Name: style_guides fk_rails_23d48c57f1; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.style_guides
    ADD CONSTRAINT fk_rails_23d48c57f1 FOREIGN KEY (account_id) REFERENCES public.accounts(id) ON DELETE CASCADE;


--
-- Name: chat_session_projects fk_rails_24faeffa39; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.chat_session_projects
    ADD CONSTRAINT fk_rails_24faeffa39 FOREIGN KEY (chat_session_id) REFERENCES public.chat_sessions(id);


--
-- Name: configuration_experiment_assignments fk_rails_250cd833e6; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.configuration_experiment_assignments
    ADD CONSTRAINT fk_rails_250cd833e6 FOREIGN KEY (configuration_experiment_variant_id) REFERENCES public.configuration_experiment_variants(id) ON DELETE CASCADE;


--
-- Name: knowledge_artifacts fk_rails_267c7f4678; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_artifacts
    ADD CONSTRAINT fk_rails_267c7f4678 FOREIGN KEY (collector_run_id) REFERENCES public.collector_runs(id) ON DELETE CASCADE;


--
-- Name: service_containers fk_rails_28ab710fe6; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.service_containers
    ADD CONSTRAINT fk_rails_28ab710fe6 FOREIGN KEY (account_id) REFERENCES public.accounts(id);


--
-- Name: configuration_experiments fk_rails_2bb513571a; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.configuration_experiments
    ADD CONSTRAINT fk_rails_2bb513571a FOREIGN KEY (account_id) REFERENCES public.accounts(id) ON DELETE CASCADE;


--
-- Name: token_usages fk_rails_2e5496eeab; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.token_usages
    ADD CONSTRAINT fk_rails_2e5496eeab FOREIGN KEY (knowledge_run_id) REFERENCES public.knowledge_runs(id) ON DELETE CASCADE;


--
-- Name: prompts fk_rails_314c3f0405; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.prompts
    ADD CONSTRAINT fk_rails_314c3f0405 FOREIGN KEY (current_version_id) REFERENCES public.prompt_versions(id) ON DELETE SET NULL;


--
-- Name: chat_session_projects fk_rails_3358d3948c; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.chat_session_projects
    ADD CONSTRAINT fk_rails_3358d3948c FOREIGN KEY (project_id) REFERENCES public.projects(id);


--
-- Name: integration_credentials fk_rails_35c37bb198; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.integration_credentials
    ADD CONSTRAINT fk_rails_35c37bb198 FOREIGN KEY (account_id) REFERENCES public.accounts(id);


--
-- Name: knowledge_artifacts fk_rails_371369f3e5; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_artifacts
    ADD CONSTRAINT fk_rails_371369f3e5 FOREIGN KEY (project_id) REFERENCES public.projects(id);


--
-- Name: linear_tokens fk_rails_377d92966e; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.linear_tokens
    ADD CONSTRAINT fk_rails_377d92966e FOREIGN KEY (account_id) REFERENCES public.accounts(id);


--
-- Name: quality_gate_thresholds fk_rails_3c6afbb230; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.quality_gate_thresholds
    ADD CONSTRAINT fk_rails_3c6afbb230 FOREIGN KEY (project_id) REFERENCES public.projects(id);


--
-- Name: prompts fk_rails_3f18c469ef; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.prompts
    ADD CONSTRAINT fk_rails_3f18c469ef FOREIGN KEY (account_id) REFERENCES public.accounts(id) ON DELETE CASCADE;


--
-- Name: mcp_server_definitions fk_rails_4071f499a8; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.mcp_server_definitions
    ADD CONSTRAINT fk_rails_4071f499a8 FOREIGN KEY (account_id) REFERENCES public.accounts(id);


--
-- Name: billing_periods fk_rails_40b114b891; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.billing_periods
    ADD CONSTRAINT fk_rails_40b114b891 FOREIGN KEY (account_id) REFERENCES public.accounts(id);


--
-- Name: prompt_versions fk_rails_45761f0a57; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.prompt_versions
    ADD CONSTRAINT fk_rails_45761f0a57 FOREIGN KEY (prompt_id) REFERENCES public.prompts(id) ON DELETE CASCADE;


--
-- Name: prompt_versions fk_rails_474b46da4e; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.prompt_versions
    ADD CONSTRAINT fk_rails_474b46da4e FOREIGN KEY (parent_version_id) REFERENCES public.prompt_versions(id) ON DELETE SET NULL;


--
-- Name: container_pool_entries fk_rails_49dc6bbeb8; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.container_pool_entries
    ADD CONSTRAINT fk_rails_49dc6bbeb8 FOREIGN KEY (project_id) REFERENCES public.projects(id) ON DELETE CASCADE;


--
-- Name: chat_messages fk_rails_4ad9cc70bd; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.chat_messages
    ADD CONSTRAINT fk_rails_4ad9cc70bd FOREIGN KEY (chat_session_id) REFERENCES public.chat_sessions(id);


--
-- Name: github_tokens fk_rails_4d276bfe2f; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.github_tokens
    ADD CONSTRAINT fk_rails_4d276bfe2f FOREIGN KEY (account_id) REFERENCES public.accounts(id);


--
-- Name: cost_budgets fk_rails_4e6c4ff426; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.cost_budgets
    ADD CONSTRAINT fk_rails_4e6c4ff426 FOREIGN KEY (project_id) REFERENCES public.projects(id) ON DELETE CASCADE;


--
-- Name: quality_pause_events fk_rails_54a2a5b60e; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.quality_pause_events
    ADD CONSTRAINT fk_rails_54a2a5b60e FOREIGN KEY (project_id) REFERENCES public.projects(id);


--
-- Name: llm_output_metrics fk_rails_5735bac119; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.llm_output_metrics
    ADD CONSTRAINT fk_rails_5735bac119 FOREIGN KEY (account_id) REFERENCES public.accounts(id) ON DELETE CASCADE;


--
-- Name: ab_test_assignments fk_rails_5c6d672759; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ab_test_assignments
    ADD CONSTRAINT fk_rails_5c6d672759 FOREIGN KEY (ab_test_variant_id) REFERENCES public.ab_test_variants(id) ON DELETE CASCADE;


--
-- Name: billing_line_items fk_rails_60a88c66a0; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.billing_line_items
    ADD CONSTRAINT fk_rails_60a88c66a0 FOREIGN KEY (billing_invoice_id) REFERENCES public.billing_invoices(id);


--
-- Name: decision_records fk_rails_6150ffb208; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.decision_records
    ADD CONSTRAINT fk_rails_6150ffb208 FOREIGN KEY (issue_id) REFERENCES public.issues(id) ON DELETE SET NULL;


--
-- Name: users fk_rails_61ac11da2b; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.users
    ADD CONSTRAINT fk_rails_61ac11da2b FOREIGN KEY (account_id) REFERENCES public.accounts(id);


--
-- Name: project_mcp_servers fk_rails_622a6e60f4; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.project_mcp_servers
    ADD CONSTRAINT fk_rails_622a6e60f4 FOREIGN KEY (mcp_server_definition_id) REFERENCES public.mcp_server_definitions(id);


--
-- Name: knowledge_audit_events fk_rails_6402bd2a4b; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_audit_events
    ADD CONSTRAINT fk_rails_6402bd2a4b FOREIGN KEY (project_id) REFERENCES public.projects(id) ON DELETE CASCADE;


--
-- Name: knowledge_runs fk_rails_64dcf0f9ee; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_runs
    ADD CONSTRAINT fk_rails_64dcf0f9ee FOREIGN KEY (project_id) REFERENCES public.projects(id) ON DELETE CASCADE;


--
-- Name: decision_records fk_rails_6575197af8; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.decision_records
    ADD CONSTRAINT fk_rails_6575197af8 FOREIGN KEY (superseded_by_id) REFERENCES public.decision_records(id) ON DELETE SET NULL;


--
-- Name: quality_pause_events fk_rails_65e6e9ab0a; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.quality_pause_events
    ADD CONSTRAINT fk_rails_65e6e9ab0a FOREIGN KEY (agent_run_id) REFERENCES public.agent_runs(id);


--
-- Name: style_guides fk_rails_6c20f86430; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.style_guides
    ADD CONSTRAINT fk_rails_6c20f86430 FOREIGN KEY (project_id) REFERENCES public.projects(id) ON DELETE CASCADE;


--
-- Name: ab_tests fk_rails_6d2afeac1b; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ab_tests
    ADD CONSTRAINT fk_rails_6d2afeac1b FOREIGN KEY (winner_variant_id) REFERENCES public.ab_test_variants(id) ON DELETE SET NULL;


--
-- Name: knowledge_links fk_rails_6fa83b1640; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_links
    ADD CONSTRAINT fk_rails_6fa83b1640 FOREIGN KEY (target_chunk_id) REFERENCES public.knowledge_chunks(id) ON DELETE CASCADE;


--
-- Name: project_service_containers fk_rails_71eeef6b43; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.project_service_containers
    ADD CONSTRAINT fk_rails_71eeef6b43 FOREIGN KEY (project_id) REFERENCES public.projects(id) ON DELETE CASCADE;


--
-- Name: provider_states fk_rails_754bcfbe12; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.provider_states
    ADD CONSTRAINT fk_rails_754bcfbe12 FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: pr_templates fk_rails_7ac0951baa; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pr_templates
    ADD CONSTRAINT fk_rails_7ac0951baa FOREIGN KEY (account_id) REFERENCES public.accounts(id) ON DELETE CASCADE;


--
-- Name: tenant_settings fk_rails_7e073f3790; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tenant_settings
    ADD CONSTRAINT fk_rails_7e073f3790 FOREIGN KEY (account_id) REFERENCES public.accounts(id);


--
-- Name: provider_api_keys fk_rails_7e4f482b74; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.provider_api_keys
    ADD CONSTRAINT fk_rails_7e4f482b74 FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: issues fk_rails_81439a1ee9; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.issues
    ADD CONSTRAINT fk_rails_81439a1ee9 FOREIGN KEY (parent_issue_id) REFERENCES public.issues(id);


--
-- Name: agent_run_anomalies fk_rails_83fa547c26; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.agent_run_anomalies
    ADD CONSTRAINT fk_rails_83fa547c26 FOREIGN KEY (agent_run_id) REFERENCES public.agent_runs(id);


--
-- Name: project_memberships fk_rails_86b046ec96; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.project_memberships
    ADD CONSTRAINT fk_rails_86b046ec96 FOREIGN KEY (user_id) REFERENCES public.users(id);


--
-- Name: collector_runs fk_rails_871d5a0172; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.collector_runs
    ADD CONSTRAINT fk_rails_871d5a0172 FOREIGN KEY (project_version_id) REFERENCES public.project_versions(id);


--
-- Name: pr_templates fk_rails_873935acd9; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pr_templates
    ADD CONSTRAINT fk_rails_873935acd9 FOREIGN KEY (project_id) REFERENCES public.projects(id) ON DELETE CASCADE;


--
-- Name: issues fk_rails_899c8f3231; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.issues
    ADD CONSTRAINT fk_rails_899c8f3231 FOREIGN KEY (project_id) REFERENCES public.projects(id);


--
-- Name: container_metrics fk_rails_8a79fe292e; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.container_metrics
    ADD CONSTRAINT fk_rails_8a79fe292e FOREIGN KEY (agent_run_id) REFERENCES public.agent_runs(id) ON DELETE CASCADE;


--
-- Name: ab_test_assignments fk_rails_8b957badbb; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ab_test_assignments
    ADD CONSTRAINT fk_rails_8b957badbb FOREIGN KEY (ab_test_id) REFERENCES public.ab_tests(id) ON DELETE CASCADE;


--
-- Name: account_memberships fk_rails_8e0ff21478; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.account_memberships
    ADD CONSTRAINT fk_rails_8e0ff21478 FOREIGN KEY (account_id) REFERENCES public.accounts(id);


--
-- Name: chat_sessions fk_rails_8f4e060e89; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.chat_sessions
    ADD CONSTRAINT fk_rails_8f4e060e89 FOREIGN KEY (account_id) REFERENCES public.accounts(id);


--
-- Name: providers fk_rails_901136bfff; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.providers
    ADD CONSTRAINT fk_rails_901136bfff FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: agent_runs fk_rails_915d7ce550; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.agent_runs
    ADD CONSTRAINT fk_rails_915d7ce550 FOREIGN KEY (project_id) REFERENCES public.projects(id) ON DELETE CASCADE;


--
-- Name: quality_recovery_actions fk_rails_91ec3867af; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.quality_recovery_actions
    ADD CONSTRAINT fk_rails_91ec3867af FOREIGN KEY (agent_run_id) REFERENCES public.agent_runs(id) ON DELETE SET NULL;


--
-- Name: context_intake_responses fk_rails_9748670498; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.context_intake_responses
    ADD CONSTRAINT fk_rails_9748670498 FOREIGN KEY (context_intake_session_id) REFERENCES public.context_intake_sessions(id);


--
-- Name: agent_run_anomalies fk_rails_98e8a44099; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.agent_run_anomalies
    ADD CONSTRAINT fk_rails_98e8a44099 FOREIGN KEY (project_id) REFERENCES public.projects(id);


--
-- Name: prompts fk_rails_98fa12453f; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.prompts
    ADD CONSTRAINT fk_rails_98fa12453f FOREIGN KEY (project_id) REFERENCES public.projects(id) ON DELETE CASCADE;


--
-- Name: chat_sessions fk_rails_9b5b542892; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.chat_sessions
    ADD CONSTRAINT fk_rails_9b5b542892 FOREIGN KEY (created_by_id) REFERENCES public.users(id);


--
-- Name: quality_thresholds fk_rails_9bcd1f06cc; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.quality_thresholds
    ADD CONSTRAINT fk_rails_9bcd1f06cc FOREIGN KEY (project_id) REFERENCES public.projects(id);


--
-- Name: prompt_versions fk_rails_9e0a501722; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.prompt_versions
    ADD CONSTRAINT fk_rails_9e0a501722 FOREIGN KEY (reviewed_by_user_id) REFERENCES public.users(id) ON DELETE SET NULL;


--
-- Name: ab_test_variants fk_rails_9fad431770; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ab_test_variants
    ADD CONSTRAINT fk_rails_9fad431770 FOREIGN KEY (ab_test_id) REFERENCES public.ab_tests(id) ON DELETE CASCADE;


--
-- Name: ab_tests fk_rails_a39f5cf5b8; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ab_tests
    ADD CONSTRAINT fk_rails_a39f5cf5b8 FOREIGN KEY (control_version_id) REFERENCES public.prompt_versions(id) ON DELETE RESTRICT;


--
-- Name: configuration_experiment_variants fk_rails_a4b182da9b; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.configuration_experiment_variants
    ADD CONSTRAINT fk_rails_a4b182da9b FOREIGN KEY (configuration_experiment_id) REFERENCES public.configuration_experiments(id) ON DELETE CASCADE;


--
-- Name: container_pool_entries fk_rails_a75e8d53a7; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.container_pool_entries
    ADD CONSTRAINT fk_rails_a75e8d53a7 FOREIGN KEY (agent_run_id) REFERENCES public.agent_runs(id) ON DELETE SET NULL;


--
-- Name: pr_templates fk_rails_a9254e0b41; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pr_templates
    ADD CONSTRAINT fk_rails_a9254e0b41 FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: linear_tokens fk_rails_acfdf06b73; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.linear_tokens
    ADD CONSTRAINT fk_rails_acfdf06b73 FOREIGN KEY (created_by_id) REFERENCES public.users(id);


--
-- Name: quality_metrics fk_rails_ae5b82e0e6; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.quality_metrics
    ADD CONSTRAINT fk_rails_ae5b82e0e6 FOREIGN KEY (agent_run_id) REFERENCES public.agent_runs(id) ON DELETE CASCADE;


--
-- Name: context_intake_sessions fk_rails_ae8a55b482; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.context_intake_sessions
    ADD CONSTRAINT fk_rails_ae8a55b482 FOREIGN KEY (project_id) REFERENCES public.projects(id);


--
-- Name: github_tokens fk_rails_ae8af8720c; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.github_tokens
    ADD CONSTRAINT fk_rails_ae8af8720c FOREIGN KEY (created_by_id) REFERENCES public.users(id);


--
-- Name: llm_output_metrics fk_rails_aebcf4d3bc; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.llm_output_metrics
    ADD CONSTRAINT fk_rails_aebcf4d3bc FOREIGN KEY (project_id) REFERENCES public.projects(id) ON DELETE CASCADE;


--
-- Name: pre_commit_requirements fk_rails_afd2d025c0; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pre_commit_requirements
    ADD CONSTRAINT fk_rails_afd2d025c0 FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: notifications fk_rails_b080fb4855; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.notifications
    ADD CONSTRAINT fk_rails_b080fb4855 FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE SET NULL;


--
-- Name: chat_sessions fk_rails_b20daa8c1f; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.chat_sessions
    ADD CONSTRAINT fk_rails_b20daa8c1f FOREIGN KEY (provider_id) REFERENCES public.providers(id);


--
-- Name: ab_test_variants fk_rails_b24d2e265c; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ab_test_variants
    ADD CONSTRAINT fk_rails_b24d2e265c FOREIGN KEY (prompt_version_id) REFERENCES public.prompt_versions(id) ON DELETE RESTRICT;


--
-- Name: context_intake_responses fk_rails_b357426cd4; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.context_intake_responses
    ADD CONSTRAINT fk_rails_b357426cd4 FOREIGN KEY (parent_response_id) REFERENCES public.context_intake_responses(id);


--
-- Name: projects fk_rails_b4884d7210; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.projects
    ADD CONSTRAINT fk_rails_b4884d7210 FOREIGN KEY (account_id) REFERENCES public.accounts(id);


--
-- Name: configuration_experiments fk_rails_ba606c78cb; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.configuration_experiments
    ADD CONSTRAINT fk_rails_ba606c78cb FOREIGN KEY (winner_variant_id) REFERENCES public.configuration_experiment_variants(id) ON DELETE SET NULL;


--
-- Name: issue_dependencies fk_rails_bc8dc02ec7; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.issue_dependencies
    ADD CONSTRAINT fk_rails_bc8dc02ec7 FOREIGN KEY (issue_id) REFERENCES public.issues(id) ON DELETE CASCADE;


--
-- Name: billing_plans fk_rails_be179be6e9; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.billing_plans
    ADD CONSTRAINT fk_rails_be179be6e9 FOREIGN KEY (account_id) REFERENCES public.accounts(id);


--
-- Name: billing_invoices fk_rails_be7a94c0fc; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.billing_invoices
    ADD CONSTRAINT fk_rails_be7a94c0fc FOREIGN KEY (account_id) REFERENCES public.accounts(id);


--
-- Name: quality_recovery_actions fk_rails_c1b71cbe0e; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.quality_recovery_actions
    ADD CONSTRAINT fk_rails_c1b71cbe0e FOREIGN KEY (project_id) REFERENCES public.projects(id) ON DELETE CASCADE;


--
-- Name: ab_tests fk_rails_c270779a73; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ab_tests
    ADD CONSTRAINT fk_rails_c270779a73 FOREIGN KEY (prompt_id) REFERENCES public.prompts(id) ON DELETE CASCADE;


--
-- Name: account_memberships fk_rails_c33721ecfa; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.account_memberships
    ADD CONSTRAINT fk_rails_c33721ecfa FOREIGN KEY (user_id) REFERENCES public.users(id);


--
-- Name: knowledge_chunks fk_rails_c8bdc15eb8; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_chunks
    ADD CONSTRAINT fk_rails_c8bdc15eb8 FOREIGN KEY (knowledge_artifact_id) REFERENCES public.knowledge_artifacts(id) ON DELETE CASCADE;


--
-- Name: billing_periods fk_rails_cb0b0e19f9; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.billing_periods
    ADD CONSTRAINT fk_rails_cb0b0e19f9 FOREIGN KEY (billing_plan_id) REFERENCES public.billing_plans(id);


--
-- Name: configuration_experiment_assignments fk_rails_cb74c9141a; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.configuration_experiment_assignments
    ADD CONSTRAINT fk_rails_cb74c9141a FOREIGN KEY (agent_run_id) REFERENCES public.agent_runs(id) ON DELETE CASCADE;


--
-- Name: pre_commit_requirements fk_rails_cba72d86fb; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pre_commit_requirements
    ADD CONSTRAINT fk_rails_cba72d86fb FOREIGN KEY (account_id) REFERENCES public.accounts(id) ON DELETE CASCADE;


--
-- Name: agent_run_logs fk_rails_cf53eb38e2; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.agent_run_logs
    ADD CONSTRAINT fk_rails_cf53eb38e2 FOREIGN KEY (agent_run_id) REFERENCES public.agent_runs(id) ON DELETE CASCADE;


--
-- Name: knowledge_recommendations fk_rails_d08a6763c1; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_recommendations
    ADD CONSTRAINT fk_rails_d08a6763c1 FOREIGN KEY (project_id) REFERENCES public.projects(id) ON DELETE CASCADE;


--
-- Name: user_settings fk_rails_d1371c6356; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_settings
    ADD CONSTRAINT fk_rails_d1371c6356 FOREIGN KEY (user_id) REFERENCES public.users(id);


--
-- Name: model_selections fk_rails_d3509f6466; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.model_selections
    ADD CONSTRAINT fk_rails_d3509f6466 FOREIGN KEY (llm_model_id) REFERENCES public.llm_models(id);


--
-- Name: agent_run_phases fk_rails_d3958a462b; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.agent_run_phases
    ADD CONSTRAINT fk_rails_d3958a462b FOREIGN KEY (agent_run_id) REFERENCES public.agent_runs(id) ON DELETE CASCADE;


--
-- Name: worktrees fk_rails_d755c96e33; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.worktrees
    ADD CONSTRAINT fk_rails_d755c96e33 FOREIGN KEY (agent_run_id) REFERENCES public.agent_runs(id) ON DELETE SET NULL;


--
-- Name: decision_record_links fk_rails_d7ba79eb50; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.decision_record_links
    ADD CONSTRAINT fk_rails_d7ba79eb50 FOREIGN KEY (decision_record_id) REFERENCES public.decision_records(id) ON DELETE CASCADE;


--
-- Name: agent_runs fk_rails_d91f524ed9; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.agent_runs
    ADD CONSTRAINT fk_rails_d91f524ed9 FOREIGN KEY (issue_id) REFERENCES public.issues(id) ON DELETE SET NULL;


--
-- Name: knowledge_links fk_rails_dacf5d45a4; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_links
    ADD CONSTRAINT fk_rails_dacf5d45a4 FOREIGN KEY (source_chunk_id) REFERENCES public.knowledge_chunks(id) ON DELETE CASCADE;


--
-- Name: context_intake_sessions fk_rails_db219caf2f; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.context_intake_sessions
    ADD CONSTRAINT fk_rails_db219caf2f FOREIGN KEY (started_by_id) REFERENCES public.users(id);


--
-- Name: quality_thresholds fk_rails_db28dabccd; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.quality_thresholds
    ADD CONSTRAINT fk_rails_db28dabccd FOREIGN KEY (account_id) REFERENCES public.accounts(id);


--
-- Name: issue_dependencies fk_rails_dd269fd4f1; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.issue_dependencies
    ADD CONSTRAINT fk_rails_dd269fd4f1 FOREIGN KEY (depends_on_issue_id) REFERENCES public.issues(id) ON DELETE CASCADE;


--
-- Name: model_selections fk_rails_e2e793f28a; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.model_selections
    ADD CONSTRAINT fk_rails_e2e793f28a FOREIGN KEY (agent_run_id) REFERENCES public.agent_runs(id) ON DELETE CASCADE;


--
-- Name: onboarding_steps fk_rails_e648887d14; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.onboarding_steps
    ADD CONSTRAINT fk_rails_e648887d14 FOREIGN KEY (account_id) REFERENCES public.accounts(id);


--
-- Name: quality_gate_events fk_rails_e6bccf21e8; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.quality_gate_events
    ADD CONSTRAINT fk_rails_e6bccf21e8 FOREIGN KEY (project_id) REFERENCES public.projects(id);


--
-- Name: quality_metrics fk_rails_ec5d0fef00; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.quality_metrics
    ADD CONSTRAINT fk_rails_ec5d0fef00 FOREIGN KEY (prompt_version_id) REFERENCES public.prompt_versions(id) ON DELETE SET NULL;


--
-- Name: projects fk_rails_ee2dd3f6b3; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.projects
    ADD CONSTRAINT fk_rails_ee2dd3f6b3 FOREIGN KEY (github_token_id) REFERENCES public.github_tokens(id);


--
-- Name: quality_gate_events fk_rails_ee58a4fc34; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.quality_gate_events
    ADD CONSTRAINT fk_rails_ee58a4fc34 FOREIGN KEY (quality_metric_id) REFERENCES public.quality_metrics(id);


--
-- Name: decision_records fk_rails_eeca9c6096; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.decision_records
    ADD CONSTRAINT fk_rails_eeca9c6096 FOREIGN KEY (agent_run_id) REFERENCES public.agent_runs(id) ON DELETE SET NULL;


--
-- Name: quality_recovery_actions fk_rails_eed3b07f00; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.quality_recovery_actions
    ADD CONSTRAINT fk_rails_eed3b07f00 FOREIGN KEY (prompt_version_id) REFERENCES public.prompt_versions(id) ON DELETE SET NULL;


--
-- Name: project_versions fk_rails_eee5ff31fd; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.project_versions
    ADD CONSTRAINT fk_rails_eee5ff31fd FOREIGN KEY (project_id) REFERENCES public.projects(id);


--
-- Name: workflow_states fk_rails_f081d0cc32; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.workflow_states
    ADD CONSTRAINT fk_rails_f081d0cc32 FOREIGN KEY (project_id) REFERENCES public.projects(id);


--
-- Name: llm_output_metrics fk_rails_f0aa7b7e3f; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.llm_output_metrics
    ADD CONSTRAINT fk_rails_f0aa7b7e3f FOREIGN KEY (prompt_version_id) REFERENCES public.prompt_versions(id) ON DELETE SET NULL;


--
-- Name: chat_sessions fk_rails_f3ce73dd5f; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.chat_sessions
    ADD CONSTRAINT fk_rails_f3ce73dd5f FOREIGN KEY (project_id) REFERENCES public.projects(id);


--
-- Name: knowledge_chunks fk_rails_f54688f9e3; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_chunks
    ADD CONSTRAINT fk_rails_f54688f9e3 FOREIGN KEY (project_id) REFERENCES public.projects(id);


--
-- Name: billing_invoices fk_rails_f725cf93cc; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.billing_invoices
    ADD CONSTRAINT fk_rails_f725cf93cc FOREIGN KEY (billing_period_id) REFERENCES public.billing_periods(id);


--
-- Name: configuration_experiment_assignments fk_rails_f9597f4b41; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.configuration_experiment_assignments
    ADD CONSTRAINT fk_rails_f9597f4b41 FOREIGN KEY (configuration_experiment_id) REFERENCES public.configuration_experiments(id) ON DELETE CASCADE;


--
-- Name: quality_gate_events fk_rails_fa1ba6a1b8; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.quality_gate_events
    ADD CONSTRAINT fk_rails_fa1ba6a1b8 FOREIGN KEY (quality_gate_threshold_id) REFERENCES public.quality_gate_thresholds(id);


--
-- Name: ab_test_assignments fk_rails_fc67a2ee84; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ab_test_assignments
    ADD CONSTRAINT fk_rails_fc67a2ee84 FOREIGN KEY (agent_run_id) REFERENCES public.agent_runs(id) ON DELETE CASCADE;


--
-- Name: worktrees fk_rails_fd82a63e04; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.worktrees
    ADD CONSTRAINT fk_rails_fd82a63e04 FOREIGN KEY (project_id) REFERENCES public.projects(id) ON DELETE CASCADE;


--
-- Name: projects fk_rails_ff595c9009; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.projects
    ADD CONSTRAINT fk_rails_ff595c9009 FOREIGN KEY (created_by_id) REFERENCES public.users(id);


--
-- Name: knowledge_usage_stats fk_rails_kus_agent_run; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_usage_stats
    ADD CONSTRAINT fk_rails_kus_agent_run FOREIGN KEY (agent_run_id) REFERENCES public.agent_runs(id) ON DELETE CASCADE;


--
-- Name: knowledge_usage_stats fk_rails_kus_project; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_usage_stats
    ADD CONSTRAINT fk_rails_kus_project FOREIGN KEY (project_id) REFERENCES public.projects(id) ON DELETE CASCADE;


--
-- Name: ab_test_assignments; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.ab_test_assignments ENABLE ROW LEVEL SECURITY;

--
-- Name: ab_test_variants; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.ab_test_variants ENABLE ROW LEVEL SECURITY;

--
-- Name: ab_tests; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.ab_tests ENABLE ROW LEVEL SECURITY;

--
-- Name: account_memberships; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.account_memberships ENABLE ROW LEVEL SECURITY;

--
-- Name: accounts; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.accounts ENABLE ROW LEVEL SECURITY;

--
-- Name: agent_coordination_signals; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.agent_coordination_signals ENABLE ROW LEVEL SECURITY;

--
-- Name: agent_run_anomalies; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.agent_run_anomalies ENABLE ROW LEVEL SECURITY;

--
-- Name: agent_run_logs; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.agent_run_logs ENABLE ROW LEVEL SECURITY;

--
-- Name: agent_run_phases; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.agent_run_phases ENABLE ROW LEVEL SECURITY;

--
-- Name: agent_runs; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.agent_runs ENABLE ROW LEVEL SECURITY;

--
-- Name: billing_invoices; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.billing_invoices ENABLE ROW LEVEL SECURITY;

--
-- Name: billing_line_items; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.billing_line_items ENABLE ROW LEVEL SECURITY;

--
-- Name: billing_periods; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.billing_periods ENABLE ROW LEVEL SECURITY;

--
-- Name: billing_plans; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.billing_plans ENABLE ROW LEVEL SECURITY;

--
-- Name: chat_messages; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.chat_messages ENABLE ROW LEVEL SECURITY;

--
-- Name: chat_session_projects; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.chat_session_projects ENABLE ROW LEVEL SECURITY;

--
-- Name: chat_sessions; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.chat_sessions ENABLE ROW LEVEL SECURITY;

--
-- Name: collector_runs; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.collector_runs ENABLE ROW LEVEL SECURITY;

--
-- Name: container_metrics; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.container_metrics ENABLE ROW LEVEL SECURITY;

--
-- Name: container_pool_entries; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.container_pool_entries ENABLE ROW LEVEL SECURITY;

--
-- Name: context_intake_responses; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.context_intake_responses ENABLE ROW LEVEL SECURITY;

--
-- Name: context_intake_sessions; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.context_intake_sessions ENABLE ROW LEVEL SECURITY;

--
-- Name: cost_budgets; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.cost_budgets ENABLE ROW LEVEL SECURITY;

--
-- Name: decision_record_links; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.decision_record_links ENABLE ROW LEVEL SECURITY;

--
-- Name: decision_records; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.decision_records ENABLE ROW LEVEL SECURITY;

--
-- Name: github_tokens; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.github_tokens ENABLE ROW LEVEL SECURITY;

--
-- Name: integration_credentials; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.integration_credentials ENABLE ROW LEVEL SECURITY;

--
-- Name: issue_dependencies; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.issue_dependencies ENABLE ROW LEVEL SECURITY;

--
-- Name: issues; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.issues ENABLE ROW LEVEL SECURITY;

--
-- Name: knowledge_artifacts; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.knowledge_artifacts ENABLE ROW LEVEL SECURITY;

--
-- Name: knowledge_audit_events; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.knowledge_audit_events ENABLE ROW LEVEL SECURITY;

--
-- Name: knowledge_chunks; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.knowledge_chunks ENABLE ROW LEVEL SECURITY;

--
-- Name: knowledge_links; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.knowledge_links ENABLE ROW LEVEL SECURITY;

--
-- Name: knowledge_recommendations; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.knowledge_recommendations ENABLE ROW LEVEL SECURITY;

--
-- Name: knowledge_runs; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.knowledge_runs ENABLE ROW LEVEL SECURITY;

--
-- Name: knowledge_usage_stats; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.knowledge_usage_stats ENABLE ROW LEVEL SECURITY;

--
-- Name: linear_tokens; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.linear_tokens ENABLE ROW LEVEL SECURITY;

--
-- Name: llm_output_metrics; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.llm_output_metrics ENABLE ROW LEVEL SECURITY;

--
-- Name: mcp_server_definitions; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.mcp_server_definitions ENABLE ROW LEVEL SECURITY;

--
-- Name: model_selections; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.model_selections ENABLE ROW LEVEL SECURITY;

--
-- Name: notification_rule_states; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.notification_rule_states ENABLE ROW LEVEL SECURITY;

--
-- Name: notifications; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.notifications ENABLE ROW LEVEL SECURITY;

--
-- Name: onboarding_steps; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.onboarding_steps ENABLE ROW LEVEL SECURITY;

--
-- Name: pr_templates; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.pr_templates ENABLE ROW LEVEL SECURITY;

--
-- Name: pre_commit_requirements; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.pre_commit_requirements ENABLE ROW LEVEL SECURITY;

--
-- Name: project_baselines; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.project_baselines ENABLE ROW LEVEL SECURITY;

--
-- Name: project_mcp_servers; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.project_mcp_servers ENABLE ROW LEVEL SECURITY;

--
-- Name: project_memberships; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.project_memberships ENABLE ROW LEVEL SECURITY;

--
-- Name: project_service_containers; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.project_service_containers ENABLE ROW LEVEL SECURITY;

--
-- Name: project_versions; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.project_versions ENABLE ROW LEVEL SECURITY;

--
-- Name: projects; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.projects ENABLE ROW LEVEL SECURITY;

--
-- Name: prompt_versions; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.prompt_versions ENABLE ROW LEVEL SECURITY;

--
-- Name: prompts; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.prompts ENABLE ROW LEVEL SECURITY;

--
-- Name: provider_api_keys; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.provider_api_keys ENABLE ROW LEVEL SECURITY;

--
-- Name: provider_states; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.provider_states ENABLE ROW LEVEL SECURITY;

--
-- Name: providers; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.providers ENABLE ROW LEVEL SECURITY;

--
-- Name: quality_gate_events; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.quality_gate_events ENABLE ROW LEVEL SECURITY;

--
-- Name: quality_gate_thresholds; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.quality_gate_thresholds ENABLE ROW LEVEL SECURITY;

--
-- Name: quality_metrics; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.quality_metrics ENABLE ROW LEVEL SECURITY;

--
-- Name: quality_pause_events; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.quality_pause_events ENABLE ROW LEVEL SECURITY;

--
-- Name: quality_recovery_actions; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.quality_recovery_actions ENABLE ROW LEVEL SECURITY;

--
-- Name: quality_thresholds; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.quality_thresholds ENABLE ROW LEVEL SECURITY;

--
-- Name: service_container_metrics; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.service_container_metrics ENABLE ROW LEVEL SECURITY;

--
-- Name: service_containers; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.service_containers ENABLE ROW LEVEL SECURITY;

--
-- Name: style_guides; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.style_guides ENABLE ROW LEVEL SECURITY;

--
-- Name: account_memberships tenant_isolation; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY tenant_isolation ON public.account_memberships USING ((public.paid_tenant_bypass() OR ((account_id = public.paid_current_account_id()) AND (EXISTS ( SELECT 1
   FROM public.users
  WHERE ((users.id = account_memberships.user_id) AND (users.account_id = public.paid_current_account_id()))))))) WITH CHECK ((public.paid_tenant_bypass() OR ((account_id = public.paid_current_account_id()) AND (EXISTS ( SELECT 1
   FROM public.users
  WHERE ((users.id = account_memberships.user_id) AND (users.account_id = public.paid_current_account_id())))))));


--
-- Name: accounts tenant_isolation; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY tenant_isolation ON public.accounts USING ((public.paid_tenant_bypass() OR (id = public.paid_current_account_id()))) WITH CHECK ((public.paid_tenant_bypass() OR ((id = public.paid_current_account_id()) OR (public.paid_current_account_id() IS NULL))));


--
-- Name: agent_coordination_signals tenant_isolation; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY tenant_isolation ON public.agent_coordination_signals USING ((public.paid_tenant_bypass() OR ((EXISTS ( SELECT 1
   FROM (public.agent_runs
     JOIN public.projects ON ((projects.id = agent_runs.project_id)))
  WHERE ((agent_runs.id = agent_coordination_signals.source_agent_run_id) AND (projects.account_id = public.paid_current_account_id())))) AND ((target_agent_run_id IS NULL) OR (EXISTS ( SELECT 1
   FROM (public.agent_runs
     JOIN public.projects ON ((projects.id = agent_runs.project_id)))
  WHERE ((agent_runs.id = agent_coordination_signals.target_agent_run_id) AND (projects.account_id = public.paid_current_account_id())))))))) WITH CHECK ((public.paid_tenant_bypass() OR ((EXISTS ( SELECT 1
   FROM (public.agent_runs
     JOIN public.projects ON ((projects.id = agent_runs.project_id)))
  WHERE ((agent_runs.id = agent_coordination_signals.source_agent_run_id) AND (projects.account_id = public.paid_current_account_id())))) AND ((target_agent_run_id IS NULL) OR (EXISTS ( SELECT 1
   FROM (public.agent_runs
     JOIN public.projects ON ((projects.id = agent_runs.project_id)))
  WHERE ((agent_runs.id = agent_coordination_signals.target_agent_run_id) AND (projects.account_id = public.paid_current_account_id()))))))));


--
-- Name: agent_run_anomalies tenant_isolation; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY tenant_isolation ON public.agent_run_anomalies USING ((public.paid_tenant_bypass() OR (EXISTS ( SELECT 1
   FROM public.projects
  WHERE ((projects.id = agent_run_anomalies.project_id) AND (projects.account_id = public.paid_current_account_id())))))) WITH CHECK ((public.paid_tenant_bypass() OR (EXISTS ( SELECT 1
   FROM public.projects
  WHERE ((projects.id = agent_run_anomalies.project_id) AND (projects.account_id = public.paid_current_account_id()))))));


--
-- Name: agent_run_logs tenant_isolation; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY tenant_isolation ON public.agent_run_logs USING ((public.paid_tenant_bypass() OR (EXISTS ( SELECT 1
   FROM (public.agent_runs
     JOIN public.projects ON ((projects.id = agent_runs.project_id)))
  WHERE ((agent_runs.id = agent_run_logs.agent_run_id) AND (projects.account_id = public.paid_current_account_id())))))) WITH CHECK ((public.paid_tenant_bypass() OR (EXISTS ( SELECT 1
   FROM (public.agent_runs
     JOIN public.projects ON ((projects.id = agent_runs.project_id)))
  WHERE ((agent_runs.id = agent_run_logs.agent_run_id) AND (projects.account_id = public.paid_current_account_id()))))));


--
-- Name: agent_run_phases tenant_isolation; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY tenant_isolation ON public.agent_run_phases USING ((public.paid_tenant_bypass() OR (EXISTS ( SELECT 1
   FROM (public.agent_runs
     JOIN public.projects ON ((projects.id = agent_runs.project_id)))
  WHERE ((agent_runs.id = agent_run_phases.agent_run_id) AND (projects.account_id = public.paid_current_account_id())))))) WITH CHECK ((public.paid_tenant_bypass() OR (EXISTS ( SELECT 1
   FROM (public.agent_runs
     JOIN public.projects ON ((projects.id = agent_runs.project_id)))
  WHERE ((agent_runs.id = agent_run_phases.agent_run_id) AND (projects.account_id = public.paid_current_account_id()))))));


--
-- Name: agent_runs tenant_isolation; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY tenant_isolation ON public.agent_runs USING ((public.paid_tenant_bypass() OR (EXISTS ( SELECT 1
   FROM public.projects
  WHERE ((projects.id = agent_runs.project_id) AND (projects.account_id = public.paid_current_account_id())))))) WITH CHECK ((public.paid_tenant_bypass() OR (EXISTS ( SELECT 1
   FROM public.projects
  WHERE ((projects.id = agent_runs.project_id) AND (projects.account_id = public.paid_current_account_id()))))));


--
-- Name: billing_invoices tenant_isolation; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY tenant_isolation ON public.billing_invoices USING ((public.paid_tenant_bypass() OR ((account_id = public.paid_current_account_id()) AND (EXISTS ( SELECT 1
   FROM public.billing_periods
  WHERE ((billing_periods.id = billing_invoices.billing_period_id) AND (billing_periods.account_id = public.paid_current_account_id()))))))) WITH CHECK ((public.paid_tenant_bypass() OR ((account_id = public.paid_current_account_id()) AND (EXISTS ( SELECT 1
   FROM public.billing_periods
  WHERE ((billing_periods.id = billing_invoices.billing_period_id) AND (billing_periods.account_id = public.paid_current_account_id())))))));


--
-- Name: billing_line_items tenant_isolation; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY tenant_isolation ON public.billing_line_items USING ((public.paid_tenant_bypass() OR (EXISTS ( SELECT 1
   FROM public.billing_invoices
  WHERE ((billing_invoices.id = billing_line_items.billing_invoice_id) AND (billing_invoices.account_id = public.paid_current_account_id())))))) WITH CHECK ((public.paid_tenant_bypass() OR (EXISTS ( SELECT 1
   FROM public.billing_invoices
  WHERE ((billing_invoices.id = billing_line_items.billing_invoice_id) AND (billing_invoices.account_id = public.paid_current_account_id()))))));


--
-- Name: billing_periods tenant_isolation; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY tenant_isolation ON public.billing_periods USING ((public.paid_tenant_bypass() OR ((account_id = public.paid_current_account_id()) AND (EXISTS ( SELECT 1
   FROM public.billing_plans
  WHERE ((billing_plans.id = billing_periods.billing_plan_id) AND (billing_plans.account_id = public.paid_current_account_id()))))))) WITH CHECK ((public.paid_tenant_bypass() OR ((account_id = public.paid_current_account_id()) AND (EXISTS ( SELECT 1
   FROM public.billing_plans
  WHERE ((billing_plans.id = billing_periods.billing_plan_id) AND (billing_plans.account_id = public.paid_current_account_id())))))));


--
-- Name: billing_plans tenant_isolation; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY tenant_isolation ON public.billing_plans USING ((public.paid_tenant_bypass() OR (account_id = public.paid_current_account_id()))) WITH CHECK ((public.paid_tenant_bypass() OR (account_id = public.paid_current_account_id())));


--
-- Name: chat_messages tenant_isolation; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY tenant_isolation ON public.chat_messages USING ((public.paid_tenant_bypass() OR (EXISTS ( SELECT 1
   FROM public.chat_sessions
  WHERE ((chat_sessions.id = chat_messages.chat_session_id) AND (chat_sessions.account_id = public.paid_current_account_id())))))) WITH CHECK ((public.paid_tenant_bypass() OR (EXISTS ( SELECT 1
   FROM public.chat_sessions
  WHERE ((chat_sessions.id = chat_messages.chat_session_id) AND (chat_sessions.account_id = public.paid_current_account_id()))))));


--
-- Name: chat_session_projects tenant_isolation; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY tenant_isolation ON public.chat_session_projects USING ((public.paid_tenant_bypass() OR ((EXISTS ( SELECT 1
   FROM public.chat_sessions
  WHERE ((chat_sessions.id = chat_session_projects.chat_session_id) AND (chat_sessions.account_id = public.paid_current_account_id())))) AND (EXISTS ( SELECT 1
   FROM public.projects
  WHERE ((projects.id = chat_session_projects.project_id) AND (projects.account_id = public.paid_current_account_id()))))))) WITH CHECK ((public.paid_tenant_bypass() OR ((EXISTS ( SELECT 1
   FROM public.chat_sessions
  WHERE ((chat_sessions.id = chat_session_projects.chat_session_id) AND (chat_sessions.account_id = public.paid_current_account_id())))) AND (EXISTS ( SELECT 1
   FROM public.projects
  WHERE ((projects.id = chat_session_projects.project_id) AND (projects.account_id = public.paid_current_account_id())))))));


--
-- Name: chat_sessions tenant_isolation; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY tenant_isolation ON public.chat_sessions USING ((public.paid_tenant_bypass() OR ((account_id = public.paid_current_account_id()) AND ((project_id IS NULL) OR (EXISTS ( SELECT 1
   FROM public.projects
  WHERE ((projects.id = chat_sessions.project_id) AND (projects.account_id = public.paid_current_account_id()))))) AND ((provider_id IS NULL) OR (EXISTS ( SELECT 1
   FROM public.providers
  WHERE ((providers.id = chat_sessions.provider_id) AND (providers.user_id IN ( SELECT users.id
           FROM public.users
          WHERE (users.account_id = public.paid_current_account_id()))))))) AND ((created_by_id IS NULL) OR (EXISTS ( SELECT 1
   FROM public.users
  WHERE ((users.id = chat_sessions.created_by_id) AND (users.account_id = public.paid_current_account_id())))))))) WITH CHECK ((public.paid_tenant_bypass() OR ((account_id = public.paid_current_account_id()) AND ((project_id IS NULL) OR (EXISTS ( SELECT 1
   FROM public.projects
  WHERE ((projects.id = chat_sessions.project_id) AND (projects.account_id = public.paid_current_account_id()))))) AND ((provider_id IS NULL) OR (EXISTS ( SELECT 1
   FROM public.providers
  WHERE ((providers.id = chat_sessions.provider_id) AND (providers.user_id IN ( SELECT users.id
           FROM public.users
          WHERE (users.account_id = public.paid_current_account_id()))))))) AND ((created_by_id IS NULL) OR (EXISTS ( SELECT 1
   FROM public.users
  WHERE ((users.id = chat_sessions.created_by_id) AND (users.account_id = public.paid_current_account_id()))))))));


--
-- Name: collector_runs tenant_isolation; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY tenant_isolation ON public.collector_runs USING ((public.paid_tenant_bypass() OR (EXISTS ( SELECT 1
   FROM (public.project_versions
     JOIN public.projects ON ((projects.id = project_versions.project_id)))
  WHERE ((project_versions.id = collector_runs.project_version_id) AND (projects.account_id = public.paid_current_account_id())))))) WITH CHECK ((public.paid_tenant_bypass() OR (EXISTS ( SELECT 1
   FROM (public.project_versions
     JOIN public.projects ON ((projects.id = project_versions.project_id)))
  WHERE ((project_versions.id = collector_runs.project_version_id) AND (projects.account_id = public.paid_current_account_id()))))));


--
-- Name: container_metrics tenant_isolation; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY tenant_isolation ON public.container_metrics USING ((public.paid_tenant_bypass() OR (EXISTS ( SELECT 1
   FROM (public.agent_runs
     JOIN public.projects ON ((projects.id = agent_runs.project_id)))
  WHERE ((agent_runs.id = container_metrics.agent_run_id) AND (projects.account_id = public.paid_current_account_id())))))) WITH CHECK ((public.paid_tenant_bypass() OR (EXISTS ( SELECT 1
   FROM (public.agent_runs
     JOIN public.projects ON ((projects.id = agent_runs.project_id)))
  WHERE ((agent_runs.id = container_metrics.agent_run_id) AND (projects.account_id = public.paid_current_account_id()))))));


--
-- Name: container_pool_entries tenant_isolation; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY tenant_isolation ON public.container_pool_entries USING ((public.paid_tenant_bypass() OR (EXISTS ( SELECT 1
   FROM public.projects
  WHERE ((projects.id = container_pool_entries.project_id) AND (projects.account_id = public.paid_current_account_id())))))) WITH CHECK ((public.paid_tenant_bypass() OR (EXISTS ( SELECT 1
   FROM public.projects
  WHERE ((projects.id = container_pool_entries.project_id) AND (projects.account_id = public.paid_current_account_id()))))));


--
-- Name: context_intake_responses tenant_isolation; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY tenant_isolation ON public.context_intake_responses USING ((public.paid_tenant_bypass() OR (EXISTS ( SELECT 1
   FROM (public.context_intake_sessions
     JOIN public.projects ON ((projects.id = context_intake_sessions.project_id)))
  WHERE ((context_intake_sessions.id = context_intake_responses.context_intake_session_id) AND (projects.account_id = public.paid_current_account_id())))))) WITH CHECK ((public.paid_tenant_bypass() OR (EXISTS ( SELECT 1
   FROM (public.context_intake_sessions
     JOIN public.projects ON ((projects.id = context_intake_sessions.project_id)))
  WHERE ((context_intake_sessions.id = context_intake_responses.context_intake_session_id) AND (projects.account_id = public.paid_current_account_id()))))));


--
-- Name: context_intake_sessions tenant_isolation; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY tenant_isolation ON public.context_intake_sessions USING ((public.paid_tenant_bypass() OR (EXISTS ( SELECT 1
   FROM public.projects
  WHERE ((projects.id = context_intake_sessions.project_id) AND (projects.account_id = public.paid_current_account_id())))))) WITH CHECK ((public.paid_tenant_bypass() OR (EXISTS ( SELECT 1
   FROM public.projects
  WHERE ((projects.id = context_intake_sessions.project_id) AND (projects.account_id = public.paid_current_account_id()))))));


--
-- Name: cost_budgets tenant_isolation; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY tenant_isolation ON public.cost_budgets USING ((public.paid_tenant_bypass() OR (EXISTS ( SELECT 1
   FROM public.projects
  WHERE ((projects.id = cost_budgets.project_id) AND (projects.account_id = public.paid_current_account_id())))))) WITH CHECK ((public.paid_tenant_bypass() OR (EXISTS ( SELECT 1
   FROM public.projects
  WHERE ((projects.id = cost_budgets.project_id) AND (projects.account_id = public.paid_current_account_id()))))));


--
-- Name: decision_record_links tenant_isolation; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY tenant_isolation ON public.decision_record_links USING ((public.paid_tenant_bypass() OR (EXISTS ( SELECT 1
   FROM (public.decision_records
     JOIN public.projects ON ((projects.id = decision_records.project_id)))
  WHERE ((decision_records.id = decision_record_links.decision_record_id) AND (projects.account_id = public.paid_current_account_id())))))) WITH CHECK ((public.paid_tenant_bypass() OR (EXISTS ( SELECT 1
   FROM (public.decision_records
     JOIN public.projects ON ((projects.id = decision_records.project_id)))
  WHERE ((decision_records.id = decision_record_links.decision_record_id) AND (projects.account_id = public.paid_current_account_id()))))));


--
-- Name: decision_records tenant_isolation; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY tenant_isolation ON public.decision_records USING ((public.paid_tenant_bypass() OR (EXISTS ( SELECT 1
   FROM public.projects
  WHERE ((projects.id = decision_records.project_id) AND (projects.account_id = public.paid_current_account_id())))))) WITH CHECK ((public.paid_tenant_bypass() OR (EXISTS ( SELECT 1
   FROM public.projects
  WHERE ((projects.id = decision_records.project_id) AND (projects.account_id = public.paid_current_account_id()))))));


--
-- Name: github_tokens tenant_isolation; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY tenant_isolation ON public.github_tokens USING ((public.paid_tenant_bypass() OR ((account_id = public.paid_current_account_id()) AND ((created_by_id IS NULL) OR (EXISTS ( SELECT 1
   FROM public.users
  WHERE ((users.id = github_tokens.created_by_id) AND (users.account_id = public.paid_current_account_id())))))))) WITH CHECK ((public.paid_tenant_bypass() OR ((account_id = public.paid_current_account_id()) AND ((created_by_id IS NULL) OR (EXISTS ( SELECT 1
   FROM public.users
  WHERE ((users.id = github_tokens.created_by_id) AND (users.account_id = public.paid_current_account_id()))))))));


--
-- Name: integration_credentials tenant_isolation; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY tenant_isolation ON public.integration_credentials USING ((public.paid_tenant_bypass() OR ((account_id = public.paid_current_account_id()) AND ((created_by_id IS NULL) OR (EXISTS ( SELECT 1
   FROM public.users
  WHERE ((users.id = integration_credentials.created_by_id) AND (users.account_id = public.paid_current_account_id())))))))) WITH CHECK ((public.paid_tenant_bypass() OR ((account_id = public.paid_current_account_id()) AND ((created_by_id IS NULL) OR (EXISTS ( SELECT 1
   FROM public.users
  WHERE ((users.id = integration_credentials.created_by_id) AND (users.account_id = public.paid_current_account_id()))))))));


--
-- Name: issue_dependencies tenant_isolation; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY tenant_isolation ON public.issue_dependencies USING ((public.paid_tenant_bypass() OR ((EXISTS ( SELECT 1
   FROM (public.issues
     JOIN public.projects ON ((projects.id = issues.project_id)))
  WHERE ((issues.id = issue_dependencies.issue_id) AND (projects.account_id = public.paid_current_account_id())))) AND ((depends_on_issue_id IS NULL) OR (EXISTS ( SELECT 1
   FROM (public.issues depends_on_issues
     JOIN public.projects ON ((projects.id = depends_on_issues.project_id)))
  WHERE ((depends_on_issues.id = issue_dependencies.depends_on_issue_id) AND (projects.account_id = public.paid_current_account_id())))))))) WITH CHECK ((public.paid_tenant_bypass() OR ((EXISTS ( SELECT 1
   FROM (public.issues
     JOIN public.projects ON ((projects.id = issues.project_id)))
  WHERE ((issues.id = issue_dependencies.issue_id) AND (projects.account_id = public.paid_current_account_id())))) AND ((depends_on_issue_id IS NULL) OR (EXISTS ( SELECT 1
   FROM (public.issues depends_on_issues
     JOIN public.projects ON ((projects.id = depends_on_issues.project_id)))
  WHERE ((depends_on_issues.id = issue_dependencies.depends_on_issue_id) AND (projects.account_id = public.paid_current_account_id()))))))));


--
-- Name: issues tenant_isolation; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY tenant_isolation ON public.issues USING ((public.paid_tenant_bypass() OR (EXISTS ( SELECT 1
   FROM public.projects
  WHERE ((projects.id = issues.project_id) AND (projects.account_id = public.paid_current_account_id())))))) WITH CHECK ((public.paid_tenant_bypass() OR (EXISTS ( SELECT 1
   FROM public.projects
  WHERE ((projects.id = issues.project_id) AND (projects.account_id = public.paid_current_account_id()))))));


--
-- Name: knowledge_artifacts tenant_isolation; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY tenant_isolation ON public.knowledge_artifacts USING ((public.paid_tenant_bypass() OR (EXISTS ( SELECT 1
   FROM public.projects
  WHERE ((projects.id = knowledge_artifacts.project_id) AND (projects.account_id = public.paid_current_account_id())))))) WITH CHECK ((public.paid_tenant_bypass() OR (EXISTS ( SELECT 1
   FROM public.projects
  WHERE ((projects.id = knowledge_artifacts.project_id) AND (projects.account_id = public.paid_current_account_id()))))));


--
-- Name: knowledge_audit_events tenant_isolation; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY tenant_isolation ON public.knowledge_audit_events USING ((public.paid_tenant_bypass() OR (EXISTS ( SELECT 1
   FROM public.projects
  WHERE ((projects.id = knowledge_audit_events.project_id) AND (projects.account_id = public.paid_current_account_id())))))) WITH CHECK ((public.paid_tenant_bypass() OR (EXISTS ( SELECT 1
   FROM public.projects
  WHERE ((projects.id = knowledge_audit_events.project_id) AND (projects.account_id = public.paid_current_account_id()))))));


--
-- Name: knowledge_chunks tenant_isolation; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY tenant_isolation ON public.knowledge_chunks USING ((public.paid_tenant_bypass() OR (EXISTS ( SELECT 1
   FROM public.projects
  WHERE ((projects.id = knowledge_chunks.project_id) AND (projects.account_id = public.paid_current_account_id())))))) WITH CHECK ((public.paid_tenant_bypass() OR (EXISTS ( SELECT 1
   FROM public.projects
  WHERE ((projects.id = knowledge_chunks.project_id) AND (projects.account_id = public.paid_current_account_id()))))));


--
-- Name: knowledge_links tenant_isolation; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY tenant_isolation ON public.knowledge_links USING ((public.paid_tenant_bypass() OR ((EXISTS ( SELECT 1
   FROM (public.knowledge_chunks
     JOIN public.projects ON ((projects.id = knowledge_chunks.project_id)))
  WHERE ((knowledge_chunks.id = knowledge_links.source_chunk_id) AND (projects.account_id = public.paid_current_account_id())))) AND (EXISTS ( SELECT 1
   FROM (public.knowledge_chunks
     JOIN public.projects ON ((projects.id = knowledge_chunks.project_id)))
  WHERE ((knowledge_chunks.id = knowledge_links.target_chunk_id) AND (projects.account_id = public.paid_current_account_id()))))))) WITH CHECK ((public.paid_tenant_bypass() OR ((EXISTS ( SELECT 1
   FROM (public.knowledge_chunks
     JOIN public.projects ON ((projects.id = knowledge_chunks.project_id)))
  WHERE ((knowledge_chunks.id = knowledge_links.source_chunk_id) AND (projects.account_id = public.paid_current_account_id())))) AND (EXISTS ( SELECT 1
   FROM (public.knowledge_chunks
     JOIN public.projects ON ((projects.id = knowledge_chunks.project_id)))
  WHERE ((knowledge_chunks.id = knowledge_links.target_chunk_id) AND (projects.account_id = public.paid_current_account_id())))))));


--
-- Name: knowledge_recommendations tenant_isolation; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY tenant_isolation ON public.knowledge_recommendations USING ((public.paid_tenant_bypass() OR (EXISTS ( SELECT 1
   FROM public.projects
  WHERE ((projects.id = knowledge_recommendations.project_id) AND (projects.account_id = public.paid_current_account_id())))))) WITH CHECK ((public.paid_tenant_bypass() OR (EXISTS ( SELECT 1
   FROM public.projects
  WHERE ((projects.id = knowledge_recommendations.project_id) AND (projects.account_id = public.paid_current_account_id()))))));


--
-- Name: knowledge_runs tenant_isolation; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY tenant_isolation ON public.knowledge_runs USING ((public.paid_tenant_bypass() OR (EXISTS ( SELECT 1
   FROM public.projects
  WHERE ((projects.id = knowledge_runs.project_id) AND (projects.account_id = public.paid_current_account_id())))))) WITH CHECK ((public.paid_tenant_bypass() OR (EXISTS ( SELECT 1
   FROM public.projects
  WHERE ((projects.id = knowledge_runs.project_id) AND (projects.account_id = public.paid_current_account_id()))))));


--
-- Name: knowledge_usage_stats tenant_isolation; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY tenant_isolation ON public.knowledge_usage_stats USING ((public.paid_tenant_bypass() OR (EXISTS ( SELECT 1
   FROM public.projects
  WHERE ((projects.id = knowledge_usage_stats.project_id) AND (projects.account_id = public.paid_current_account_id())))))) WITH CHECK ((public.paid_tenant_bypass() OR (EXISTS ( SELECT 1
   FROM public.projects
  WHERE ((projects.id = knowledge_usage_stats.project_id) AND (projects.account_id = public.paid_current_account_id()))))));


--
-- Name: linear_tokens tenant_isolation; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY tenant_isolation ON public.linear_tokens USING ((public.paid_tenant_bypass() OR ((account_id = public.paid_current_account_id()) AND ((created_by_id IS NULL) OR (EXISTS ( SELECT 1
   FROM public.users
  WHERE ((users.id = linear_tokens.created_by_id) AND (users.account_id = public.paid_current_account_id())))))))) WITH CHECK ((public.paid_tenant_bypass() OR ((account_id = public.paid_current_account_id()) AND ((created_by_id IS NULL) OR (EXISTS ( SELECT 1
   FROM public.users
  WHERE ((users.id = linear_tokens.created_by_id) AND (users.account_id = public.paid_current_account_id()))))))));


--
-- Name: llm_output_metrics tenant_isolation; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY tenant_isolation ON public.llm_output_metrics USING ((public.paid_tenant_bypass() OR (account_id = public.paid_current_account_id()))) WITH CHECK ((public.paid_tenant_bypass() OR (account_id = public.paid_current_account_id())));


--
-- Name: mcp_server_definitions tenant_isolation; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY tenant_isolation ON public.mcp_server_definitions USING ((public.paid_tenant_bypass() OR (account_id = public.paid_current_account_id()))) WITH CHECK ((public.paid_tenant_bypass() OR (account_id = public.paid_current_account_id())));


--
-- Name: model_selections tenant_isolation; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY tenant_isolation ON public.model_selections USING ((public.paid_tenant_bypass() OR (EXISTS ( SELECT 1
   FROM (public.agent_runs
     JOIN public.projects ON ((projects.id = agent_runs.project_id)))
  WHERE ((agent_runs.id = model_selections.agent_run_id) AND (projects.account_id = public.paid_current_account_id())))))) WITH CHECK ((public.paid_tenant_bypass() OR (EXISTS ( SELECT 1
   FROM (public.agent_runs
     JOIN public.projects ON ((projects.id = agent_runs.project_id)))
  WHERE ((agent_runs.id = model_selections.agent_run_id) AND (projects.account_id = public.paid_current_account_id()))))));


--
-- Name: notification_rule_states tenant_isolation; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY tenant_isolation ON public.notification_rule_states USING ((public.paid_tenant_bypass() OR (account_id = public.paid_current_account_id()))) WITH CHECK ((public.paid_tenant_bypass() OR (account_id = public.paid_current_account_id())));


--
-- Name: notifications tenant_isolation; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY tenant_isolation ON public.notifications USING ((public.paid_tenant_bypass() OR ((account_id = public.paid_current_account_id()) AND ((user_id IS NULL) OR (EXISTS ( SELECT 1
   FROM public.users
  WHERE ((users.id = notifications.user_id) AND (users.account_id = public.paid_current_account_id())))))))) WITH CHECK ((public.paid_tenant_bypass() OR ((account_id = public.paid_current_account_id()) AND ((user_id IS NULL) OR (EXISTS ( SELECT 1
   FROM public.users
  WHERE ((users.id = notifications.user_id) AND (users.account_id = public.paid_current_account_id()))))))));


--
-- Name: onboarding_steps tenant_isolation; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY tenant_isolation ON public.onboarding_steps USING ((public.paid_tenant_bypass() OR (account_id = public.paid_current_account_id()))) WITH CHECK ((public.paid_tenant_bypass() OR (account_id = public.paid_current_account_id())));


--
-- Name: pr_templates tenant_isolation; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY tenant_isolation ON public.pr_templates USING ((public.paid_tenant_bypass() OR ((account_id = public.paid_current_account_id()) AND ((project_id IS NULL) OR (EXISTS ( SELECT 1
   FROM public.projects
  WHERE ((projects.id = pr_templates.project_id) AND (projects.account_id = public.paid_current_account_id()))))) AND ((user_id IS NULL) OR (EXISTS ( SELECT 1
   FROM public.users
  WHERE ((users.id = pr_templates.user_id) AND (users.account_id = public.paid_current_account_id())))))))) WITH CHECK ((public.paid_tenant_bypass() OR ((account_id = public.paid_current_account_id()) AND ((project_id IS NULL) OR (EXISTS ( SELECT 1
   FROM public.projects
  WHERE ((projects.id = pr_templates.project_id) AND (projects.account_id = public.paid_current_account_id()))))) AND ((user_id IS NULL) OR (EXISTS ( SELECT 1
   FROM public.users
  WHERE ((users.id = pr_templates.user_id) AND (users.account_id = public.paid_current_account_id()))))))));


--
-- Name: pre_commit_requirements tenant_isolation; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY tenant_isolation ON public.pre_commit_requirements USING ((public.paid_tenant_bypass() OR ((account_id = public.paid_current_account_id()) AND ((project_id IS NULL) OR (EXISTS ( SELECT 1
   FROM public.projects
  WHERE ((projects.id = pre_commit_requirements.project_id) AND (projects.account_id = public.paid_current_account_id()))))) AND ((user_id IS NULL) OR (EXISTS ( SELECT 1
   FROM public.users
  WHERE ((users.id = pre_commit_requirements.user_id) AND (users.account_id = public.paid_current_account_id())))))))) WITH CHECK ((public.paid_tenant_bypass() OR ((account_id = public.paid_current_account_id()) AND ((project_id IS NULL) OR (EXISTS ( SELECT 1
   FROM public.projects
  WHERE ((projects.id = pre_commit_requirements.project_id) AND (projects.account_id = public.paid_current_account_id()))))) AND ((user_id IS NULL) OR (EXISTS ( SELECT 1
   FROM public.users
  WHERE ((users.id = pre_commit_requirements.user_id) AND (users.account_id = public.paid_current_account_id()))))))));


--
-- Name: project_baselines tenant_isolation; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY tenant_isolation ON public.project_baselines USING ((public.paid_tenant_bypass() OR (EXISTS ( SELECT 1
   FROM public.projects
  WHERE ((projects.id = project_baselines.project_id) AND (projects.account_id = public.paid_current_account_id())))))) WITH CHECK ((public.paid_tenant_bypass() OR (EXISTS ( SELECT 1
   FROM public.projects
  WHERE ((projects.id = project_baselines.project_id) AND (projects.account_id = public.paid_current_account_id()))))));


--
-- Name: project_mcp_servers tenant_isolation; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY tenant_isolation ON public.project_mcp_servers USING ((public.paid_tenant_bypass() OR ((EXISTS ( SELECT 1
   FROM public.projects
  WHERE ((projects.id = project_mcp_servers.project_id) AND (projects.account_id = public.paid_current_account_id())))) AND (EXISTS ( SELECT 1
   FROM public.mcp_server_definitions
  WHERE ((mcp_server_definitions.id = project_mcp_servers.mcp_server_definition_id) AND (mcp_server_definitions.account_id = public.paid_current_account_id()))))))) WITH CHECK ((public.paid_tenant_bypass() OR ((EXISTS ( SELECT 1
   FROM public.projects
  WHERE ((projects.id = project_mcp_servers.project_id) AND (projects.account_id = public.paid_current_account_id())))) AND (EXISTS ( SELECT 1
   FROM public.mcp_server_definitions
  WHERE ((mcp_server_definitions.id = project_mcp_servers.mcp_server_definition_id) AND (mcp_server_definitions.account_id = public.paid_current_account_id())))))));


--
-- Name: project_memberships tenant_isolation; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY tenant_isolation ON public.project_memberships USING ((public.paid_tenant_bypass() OR ((EXISTS ( SELECT 1
   FROM public.projects
  WHERE ((projects.id = project_memberships.project_id) AND (projects.account_id = public.paid_current_account_id())))) AND (EXISTS ( SELECT 1
   FROM public.users
  WHERE ((users.id = project_memberships.user_id) AND (users.account_id = public.paid_current_account_id()))))))) WITH CHECK ((public.paid_tenant_bypass() OR ((EXISTS ( SELECT 1
   FROM public.projects
  WHERE ((projects.id = project_memberships.project_id) AND (projects.account_id = public.paid_current_account_id())))) AND (EXISTS ( SELECT 1
   FROM public.users
  WHERE ((users.id = project_memberships.user_id) AND (users.account_id = public.paid_current_account_id())))))));


--
-- Name: project_service_containers tenant_isolation; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY tenant_isolation ON public.project_service_containers USING ((public.paid_tenant_bypass() OR ((EXISTS ( SELECT 1
   FROM public.projects
  WHERE ((projects.id = project_service_containers.project_id) AND (projects.account_id = public.paid_current_account_id())))) AND (EXISTS ( SELECT 1
   FROM public.service_containers
  WHERE ((service_containers.id = project_service_containers.service_container_id) AND (service_containers.account_id = public.paid_current_account_id()))))))) WITH CHECK ((public.paid_tenant_bypass() OR ((EXISTS ( SELECT 1
   FROM public.projects
  WHERE ((projects.id = project_service_containers.project_id) AND (projects.account_id = public.paid_current_account_id())))) AND (EXISTS ( SELECT 1
   FROM public.service_containers
  WHERE ((service_containers.id = project_service_containers.service_container_id) AND (service_containers.account_id = public.paid_current_account_id())))))));


--
-- Name: project_versions tenant_isolation; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY tenant_isolation ON public.project_versions USING ((public.paid_tenant_bypass() OR (EXISTS ( SELECT 1
   FROM public.projects
  WHERE ((projects.id = project_versions.project_id) AND (projects.account_id = public.paid_current_account_id())))))) WITH CHECK ((public.paid_tenant_bypass() OR (EXISTS ( SELECT 1
   FROM public.projects
  WHERE ((projects.id = project_versions.project_id) AND (projects.account_id = public.paid_current_account_id()))))));


--
-- Name: projects tenant_isolation; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY tenant_isolation ON public.projects USING ((public.paid_tenant_bypass() OR ((account_id = public.paid_current_account_id()) AND (EXISTS ( SELECT 1
   FROM public.github_tokens
  WHERE ((github_tokens.id = projects.github_token_id) AND (github_tokens.account_id = public.paid_current_account_id())))) AND ((created_by_id IS NULL) OR (EXISTS ( SELECT 1
   FROM public.users
  WHERE ((users.id = projects.created_by_id) AND (users.account_id = public.paid_current_account_id())))))))) WITH CHECK ((public.paid_tenant_bypass() OR ((account_id = public.paid_current_account_id()) AND (EXISTS ( SELECT 1
   FROM public.github_tokens
  WHERE ((github_tokens.id = projects.github_token_id) AND (github_tokens.account_id = public.paid_current_account_id())))) AND ((created_by_id IS NULL) OR (EXISTS ( SELECT 1
   FROM public.users
  WHERE ((users.id = projects.created_by_id) AND (users.account_id = public.paid_current_account_id()))))))));


--
-- Name: provider_api_keys tenant_isolation; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY tenant_isolation ON public.provider_api_keys USING ((public.paid_tenant_bypass() OR (EXISTS ( SELECT 1
   FROM public.users
  WHERE ((users.id = provider_api_keys.user_id) AND (users.account_id = public.paid_current_account_id())))))) WITH CHECK ((public.paid_tenant_bypass() OR (EXISTS ( SELECT 1
   FROM public.users
  WHERE ((users.id = provider_api_keys.user_id) AND (users.account_id = public.paid_current_account_id()))))));


--
-- Name: provider_states tenant_isolation; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY tenant_isolation ON public.provider_states USING ((public.paid_tenant_bypass() OR (EXISTS ( SELECT 1
   FROM public.users
  WHERE ((users.id = provider_states.user_id) AND (users.account_id = public.paid_current_account_id())))))) WITH CHECK ((public.paid_tenant_bypass() OR (EXISTS ( SELECT 1
   FROM public.users
  WHERE ((users.id = provider_states.user_id) AND (users.account_id = public.paid_current_account_id()))))));


--
-- Name: providers tenant_isolation; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY tenant_isolation ON public.providers USING ((public.paid_tenant_bypass() OR (EXISTS ( SELECT 1
   FROM public.users
  WHERE ((users.id = providers.user_id) AND (users.account_id = public.paid_current_account_id())))))) WITH CHECK ((public.paid_tenant_bypass() OR (EXISTS ( SELECT 1
   FROM public.users
  WHERE ((users.id = providers.user_id) AND (users.account_id = public.paid_current_account_id()))))));


--
-- Name: quality_gate_events tenant_isolation; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY tenant_isolation ON public.quality_gate_events USING ((public.paid_tenant_bypass() OR (EXISTS ( SELECT 1
   FROM public.projects
  WHERE ((projects.id = quality_gate_events.project_id) AND (projects.account_id = public.paid_current_account_id())))))) WITH CHECK ((public.paid_tenant_bypass() OR (EXISTS ( SELECT 1
   FROM public.projects
  WHERE ((projects.id = quality_gate_events.project_id) AND (projects.account_id = public.paid_current_account_id()))))));


--
-- Name: quality_gate_thresholds tenant_isolation; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY tenant_isolation ON public.quality_gate_thresholds USING ((public.paid_tenant_bypass() OR (EXISTS ( SELECT 1
   FROM public.projects
  WHERE ((projects.id = quality_gate_thresholds.project_id) AND (projects.account_id = public.paid_current_account_id())))))) WITH CHECK ((public.paid_tenant_bypass() OR (EXISTS ( SELECT 1
   FROM public.projects
  WHERE ((projects.id = quality_gate_thresholds.project_id) AND (projects.account_id = public.paid_current_account_id()))))));


--
-- Name: quality_metrics tenant_isolation; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY tenant_isolation ON public.quality_metrics USING ((public.paid_tenant_bypass() OR (EXISTS ( SELECT 1
   FROM (public.agent_runs
     JOIN public.projects ON ((projects.id = agent_runs.project_id)))
  WHERE ((agent_runs.id = quality_metrics.agent_run_id) AND (projects.account_id = public.paid_current_account_id())))))) WITH CHECK ((public.paid_tenant_bypass() OR (EXISTS ( SELECT 1
   FROM (public.agent_runs
     JOIN public.projects ON ((projects.id = agent_runs.project_id)))
  WHERE ((agent_runs.id = quality_metrics.agent_run_id) AND (projects.account_id = public.paid_current_account_id()))))));


--
-- Name: quality_pause_events tenant_isolation; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY tenant_isolation ON public.quality_pause_events USING ((public.paid_tenant_bypass() OR (EXISTS ( SELECT 1
   FROM public.projects
  WHERE ((projects.id = quality_pause_events.project_id) AND (projects.account_id = public.paid_current_account_id())))))) WITH CHECK ((public.paid_tenant_bypass() OR (EXISTS ( SELECT 1
   FROM public.projects
  WHERE ((projects.id = quality_pause_events.project_id) AND (projects.account_id = public.paid_current_account_id()))))));


--
-- Name: quality_recovery_actions tenant_isolation; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY tenant_isolation ON public.quality_recovery_actions USING ((public.paid_tenant_bypass() OR (EXISTS ( SELECT 1
   FROM public.projects
  WHERE ((projects.id = quality_recovery_actions.project_id) AND (projects.account_id = public.paid_current_account_id())))))) WITH CHECK ((public.paid_tenant_bypass() OR (EXISTS ( SELECT 1
   FROM public.projects
  WHERE ((projects.id = quality_recovery_actions.project_id) AND (projects.account_id = public.paid_current_account_id()))))));


--
-- Name: quality_thresholds tenant_isolation; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY tenant_isolation ON public.quality_thresholds USING ((public.paid_tenant_bypass() OR ((account_id = public.paid_current_account_id()) AND ((project_id IS NULL) OR (EXISTS ( SELECT 1
   FROM public.projects
  WHERE ((projects.id = quality_thresholds.project_id) AND (projects.account_id = public.paid_current_account_id())))))))) WITH CHECK ((public.paid_tenant_bypass() OR ((account_id = public.paid_current_account_id()) AND ((project_id IS NULL) OR (EXISTS ( SELECT 1
   FROM public.projects
  WHERE ((projects.id = quality_thresholds.project_id) AND (projects.account_id = public.paid_current_account_id()))))))));


--
-- Name: service_container_metrics tenant_isolation; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY tenant_isolation ON public.service_container_metrics USING ((public.paid_tenant_bypass() OR (EXISTS ( SELECT 1
   FROM public.service_containers
  WHERE ((service_containers.id = service_container_metrics.service_container_id) AND (service_containers.account_id = public.paid_current_account_id())))))) WITH CHECK ((public.paid_tenant_bypass() OR (EXISTS ( SELECT 1
   FROM public.service_containers
  WHERE ((service_containers.id = service_container_metrics.service_container_id) AND (service_containers.account_id = public.paid_current_account_id()))))));


--
-- Name: service_containers tenant_isolation; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY tenant_isolation ON public.service_containers USING ((public.paid_tenant_bypass() OR (account_id = public.paid_current_account_id()))) WITH CHECK ((public.paid_tenant_bypass() OR (account_id = public.paid_current_account_id())));


--
-- Name: tenant_settings tenant_isolation; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY tenant_isolation ON public.tenant_settings USING ((public.paid_tenant_bypass() OR (account_id = public.paid_current_account_id()))) WITH CHECK ((public.paid_tenant_bypass() OR (account_id = public.paid_current_account_id())));


--
-- Name: token_usages tenant_isolation; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY tenant_isolation ON public.token_usages USING ((public.paid_tenant_bypass() OR (((agent_run_id IS NOT NULL) AND (EXISTS ( SELECT 1
   FROM (public.agent_runs
     JOIN public.projects ON ((projects.id = agent_runs.project_id)))
  WHERE ((agent_runs.id = token_usages.agent_run_id) AND (projects.account_id = public.paid_current_account_id()))))) OR ((knowledge_run_id IS NOT NULL) AND (EXISTS ( SELECT 1
   FROM (public.knowledge_runs
     JOIN public.projects ON ((projects.id = knowledge_runs.project_id)))
  WHERE ((knowledge_runs.id = token_usages.knowledge_run_id) AND (projects.account_id = public.paid_current_account_id())))))))) WITH CHECK ((public.paid_tenant_bypass() OR (((agent_run_id IS NOT NULL) AND (EXISTS ( SELECT 1
   FROM (public.agent_runs
     JOIN public.projects ON ((projects.id = agent_runs.project_id)))
  WHERE ((agent_runs.id = token_usages.agent_run_id) AND (projects.account_id = public.paid_current_account_id()))))) OR ((knowledge_run_id IS NOT NULL) AND (EXISTS ( SELECT 1
   FROM (public.knowledge_runs
     JOIN public.projects ON ((projects.id = knowledge_runs.project_id)))
  WHERE ((knowledge_runs.id = token_usages.knowledge_run_id) AND (projects.account_id = public.paid_current_account_id()))))))));


--
-- Name: tracker_configurations tenant_isolation; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY tenant_isolation ON public.tracker_configurations USING ((public.paid_tenant_bypass() OR ((((configurable_type)::text = 'Account'::text) AND (configurable_id = public.paid_current_account_id())) OR (((configurable_type)::text = 'Project'::text) AND (EXISTS ( SELECT 1
   FROM public.projects
  WHERE ((projects.id = tracker_configurations.configurable_id) AND (projects.account_id = public.paid_current_account_id())))))))) WITH CHECK ((public.paid_tenant_bypass() OR ((((configurable_type)::text = 'Account'::text) AND (configurable_id = public.paid_current_account_id())) OR (((configurable_type)::text = 'Project'::text) AND (EXISTS ( SELECT 1
   FROM public.projects
  WHERE ((projects.id = tracker_configurations.configurable_id) AND (projects.account_id = public.paid_current_account_id()))))))));


--
-- Name: user_settings tenant_isolation; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY tenant_isolation ON public.user_settings USING ((public.paid_tenant_bypass() OR (EXISTS ( SELECT 1
   FROM public.users
  WHERE ((users.id = user_settings.user_id) AND (users.account_id = public.paid_current_account_id())))))) WITH CHECK ((public.paid_tenant_bypass() OR (EXISTS ( SELECT 1
   FROM public.users
  WHERE ((users.id = user_settings.user_id) AND (users.account_id = public.paid_current_account_id()))))));


--
-- Name: users tenant_isolation; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY tenant_isolation ON public.users USING ((public.paid_tenant_bypass() OR (account_id = public.paid_current_account_id()))) WITH CHECK ((public.paid_tenant_bypass() OR (account_id = public.paid_current_account_id())));


--
-- Name: workflow_states tenant_isolation; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY tenant_isolation ON public.workflow_states USING ((public.paid_tenant_bypass() OR (EXISTS ( SELECT 1
   FROM public.projects
  WHERE ((projects.id = workflow_states.project_id) AND (projects.account_id = public.paid_current_account_id())))))) WITH CHECK ((public.paid_tenant_bypass() OR (EXISTS ( SELECT 1
   FROM public.projects
  WHERE ((projects.id = workflow_states.project_id) AND (projects.account_id = public.paid_current_account_id()))))));


--
-- Name: worktrees tenant_isolation; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY tenant_isolation ON public.worktrees USING ((public.paid_tenant_bypass() OR (EXISTS ( SELECT 1
   FROM public.projects
  WHERE ((projects.id = worktrees.project_id) AND (projects.account_id = public.paid_current_account_id())))))) WITH CHECK ((public.paid_tenant_bypass() OR (EXISTS ( SELECT 1
   FROM public.projects
  WHERE ((projects.id = worktrees.project_id) AND (projects.account_id = public.paid_current_account_id()))))));


--
-- Name: ab_test_assignments tenant_isolation_delete; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY tenant_isolation_delete ON public.ab_test_assignments FOR DELETE USING ((public.paid_tenant_bypass() OR ((EXISTS ( SELECT 1
   FROM (public.ab_tests
     JOIN public.prompts ON ((prompts.id = ab_tests.prompt_id)))
  WHERE ((ab_tests.id = ab_test_assignments.ab_test_id) AND (prompts.account_id = public.paid_current_account_id()) AND ((prompts.project_id IS NULL) OR (EXISTS ( SELECT 1
           FROM public.projects
          WHERE ((projects.id = prompts.project_id) AND (projects.account_id = public.paid_current_account_id())))))))) AND (EXISTS ( SELECT 1
   FROM (public.agent_runs
     JOIN public.projects ON ((projects.id = agent_runs.project_id)))
  WHERE ((agent_runs.id = ab_test_assignments.agent_run_id) AND (projects.account_id = public.paid_current_account_id())))))));


--
-- Name: ab_test_variants tenant_isolation_delete; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY tenant_isolation_delete ON public.ab_test_variants FOR DELETE USING ((public.paid_tenant_bypass() OR (EXISTS ( SELECT 1
   FROM (public.ab_tests
     JOIN public.prompts ON ((prompts.id = ab_tests.prompt_id)))
  WHERE ((ab_tests.id = ab_test_variants.ab_test_id) AND (prompts.account_id = public.paid_current_account_id()) AND ((prompts.project_id IS NULL) OR (EXISTS ( SELECT 1
           FROM public.projects
          WHERE ((projects.id = prompts.project_id) AND (projects.account_id = public.paid_current_account_id()))))))))));


--
-- Name: ab_tests tenant_isolation_delete; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY tenant_isolation_delete ON public.ab_tests FOR DELETE USING ((public.paid_tenant_bypass() OR (EXISTS ( SELECT 1
   FROM public.prompts
  WHERE ((prompts.id = ab_tests.prompt_id) AND (prompts.account_id = public.paid_current_account_id()) AND ((prompts.project_id IS NULL) OR (EXISTS ( SELECT 1
           FROM public.projects
          WHERE ((projects.id = prompts.project_id) AND (projects.account_id = public.paid_current_account_id()))))))))));


--
-- Name: prompt_versions tenant_isolation_delete; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY tenant_isolation_delete ON public.prompt_versions FOR DELETE USING ((public.paid_tenant_bypass() OR (EXISTS ( SELECT 1
   FROM public.prompts
  WHERE ((prompts.id = prompt_versions.prompt_id) AND (prompts.account_id = public.paid_current_account_id()) AND ((prompts.project_id IS NULL) OR (EXISTS ( SELECT 1
           FROM public.projects
          WHERE ((projects.id = prompts.project_id) AND (projects.account_id = public.paid_current_account_id()))))))))));


--
-- Name: prompts tenant_isolation_delete; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY tenant_isolation_delete ON public.prompts FOR DELETE USING ((public.paid_tenant_bypass() OR ((account_id = public.paid_current_account_id()) AND ((project_id IS NULL) OR (EXISTS ( SELECT 1
   FROM public.projects
  WHERE ((projects.id = prompts.project_id) AND (projects.account_id = public.paid_current_account_id()))))))));


--
-- Name: style_guides tenant_isolation_delete; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY tenant_isolation_delete ON public.style_guides FOR DELETE USING ((public.paid_tenant_bypass() OR ((account_id = public.paid_current_account_id()) AND ((project_id IS NULL) OR (EXISTS ( SELECT 1
   FROM public.projects
  WHERE ((projects.id = style_guides.project_id) AND (projects.account_id = public.paid_current_account_id()))))))));


--
-- Name: ab_test_assignments tenant_isolation_insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY tenant_isolation_insert ON public.ab_test_assignments FOR INSERT WITH CHECK ((public.paid_tenant_bypass() OR ((EXISTS ( SELECT 1
   FROM (public.ab_tests
     JOIN public.prompts ON ((prompts.id = ab_tests.prompt_id)))
  WHERE ((ab_tests.id = ab_test_assignments.ab_test_id) AND (prompts.account_id = public.paid_current_account_id()) AND ((prompts.project_id IS NULL) OR (EXISTS ( SELECT 1
           FROM public.projects
          WHERE ((projects.id = prompts.project_id) AND (projects.account_id = public.paid_current_account_id())))))))) AND (EXISTS ( SELECT 1
   FROM (public.agent_runs
     JOIN public.projects ON ((projects.id = agent_runs.project_id)))
  WHERE ((agent_runs.id = ab_test_assignments.agent_run_id) AND (projects.account_id = public.paid_current_account_id())))))));


--
-- Name: ab_test_variants tenant_isolation_insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY tenant_isolation_insert ON public.ab_test_variants FOR INSERT WITH CHECK ((public.paid_tenant_bypass() OR (EXISTS ( SELECT 1
   FROM (public.ab_tests
     JOIN public.prompts ON ((prompts.id = ab_tests.prompt_id)))
  WHERE ((ab_tests.id = ab_test_variants.ab_test_id) AND (prompts.account_id = public.paid_current_account_id()) AND ((prompts.project_id IS NULL) OR (EXISTS ( SELECT 1
           FROM public.projects
          WHERE ((projects.id = prompts.project_id) AND (projects.account_id = public.paid_current_account_id()))))))))));


--
-- Name: ab_tests tenant_isolation_insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY tenant_isolation_insert ON public.ab_tests FOR INSERT WITH CHECK ((public.paid_tenant_bypass() OR (EXISTS ( SELECT 1
   FROM public.prompts
  WHERE ((prompts.id = ab_tests.prompt_id) AND (prompts.account_id = public.paid_current_account_id()) AND ((prompts.project_id IS NULL) OR (EXISTS ( SELECT 1
           FROM public.projects
          WHERE ((projects.id = prompts.project_id) AND (projects.account_id = public.paid_current_account_id()))))))))));


--
-- Name: prompt_versions tenant_isolation_insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY tenant_isolation_insert ON public.prompt_versions FOR INSERT WITH CHECK ((public.paid_tenant_bypass() OR (EXISTS ( SELECT 1
   FROM public.prompts
  WHERE ((prompts.id = prompt_versions.prompt_id) AND (prompts.account_id = public.paid_current_account_id()) AND ((prompts.project_id IS NULL) OR (EXISTS ( SELECT 1
           FROM public.projects
          WHERE ((projects.id = prompts.project_id) AND (projects.account_id = public.paid_current_account_id()))))))))));


--
-- Name: prompts tenant_isolation_insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY tenant_isolation_insert ON public.prompts FOR INSERT WITH CHECK ((public.paid_tenant_bypass() OR ((account_id = public.paid_current_account_id()) AND ((project_id IS NULL) OR (EXISTS ( SELECT 1
   FROM public.projects
  WHERE ((projects.id = prompts.project_id) AND (projects.account_id = public.paid_current_account_id()))))))));


--
-- Name: style_guides tenant_isolation_insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY tenant_isolation_insert ON public.style_guides FOR INSERT WITH CHECK ((public.paid_tenant_bypass() OR ((account_id = public.paid_current_account_id()) AND ((project_id IS NULL) OR (EXISTS ( SELECT 1
   FROM public.projects
  WHERE ((projects.id = style_guides.project_id) AND (projects.account_id = public.paid_current_account_id()))))))));


--
-- Name: ab_test_assignments tenant_isolation_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY tenant_isolation_select ON public.ab_test_assignments FOR SELECT USING ((public.paid_tenant_bypass() OR ((EXISTS ( SELECT 1
   FROM (public.ab_tests
     JOIN public.prompts ON ((prompts.id = ab_tests.prompt_id)))
  WHERE ((ab_tests.id = ab_test_assignments.ab_test_id) AND ((prompts.account_id IS NULL) OR (prompts.account_id = public.paid_current_account_id()))))) AND (EXISTS ( SELECT 1
   FROM (public.agent_runs
     JOIN public.projects ON ((projects.id = agent_runs.project_id)))
  WHERE ((agent_runs.id = ab_test_assignments.agent_run_id) AND (projects.account_id = public.paid_current_account_id())))))));


--
-- Name: ab_test_variants tenant_isolation_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY tenant_isolation_select ON public.ab_test_variants FOR SELECT USING ((public.paid_tenant_bypass() OR (EXISTS ( SELECT 1
   FROM (public.ab_tests
     JOIN public.prompts ON ((prompts.id = ab_tests.prompt_id)))
  WHERE ((ab_tests.id = ab_test_variants.ab_test_id) AND ((prompts.account_id IS NULL) OR (prompts.account_id = public.paid_current_account_id())))))));


--
-- Name: ab_tests tenant_isolation_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY tenant_isolation_select ON public.ab_tests FOR SELECT USING ((public.paid_tenant_bypass() OR (EXISTS ( SELECT 1
   FROM public.prompts
  WHERE ((prompts.id = ab_tests.prompt_id) AND ((prompts.account_id IS NULL) OR (prompts.account_id = public.paid_current_account_id())))))));


--
-- Name: prompt_versions tenant_isolation_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY tenant_isolation_select ON public.prompt_versions FOR SELECT USING ((public.paid_tenant_bypass() OR (EXISTS ( SELECT 1
   FROM public.prompts
  WHERE ((prompts.id = prompt_versions.prompt_id) AND ((prompts.account_id IS NULL) OR (prompts.account_id = public.paid_current_account_id())))))));


--
-- Name: prompts tenant_isolation_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY tenant_isolation_select ON public.prompts FOR SELECT USING ((public.paid_tenant_bypass() OR ((account_id IS NULL) OR ((account_id = public.paid_current_account_id()) AND ((project_id IS NULL) OR (EXISTS ( SELECT 1
   FROM public.projects
  WHERE ((projects.id = prompts.project_id) AND (projects.account_id = public.paid_current_account_id())))))))));


--
-- Name: style_guides tenant_isolation_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY tenant_isolation_select ON public.style_guides FOR SELECT USING ((public.paid_tenant_bypass() OR ((account_id IS NULL) OR ((account_id = public.paid_current_account_id()) AND ((project_id IS NULL) OR (EXISTS ( SELECT 1
   FROM public.projects
  WHERE ((projects.id = style_guides.project_id) AND (projects.account_id = public.paid_current_account_id())))))))));


--
-- Name: ab_test_assignments tenant_isolation_update; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY tenant_isolation_update ON public.ab_test_assignments FOR UPDATE USING ((public.paid_tenant_bypass() OR ((EXISTS ( SELECT 1
   FROM (public.ab_tests
     JOIN public.prompts ON ((prompts.id = ab_tests.prompt_id)))
  WHERE ((ab_tests.id = ab_test_assignments.ab_test_id) AND (prompts.account_id = public.paid_current_account_id()) AND ((prompts.project_id IS NULL) OR (EXISTS ( SELECT 1
           FROM public.projects
          WHERE ((projects.id = prompts.project_id) AND (projects.account_id = public.paid_current_account_id())))))))) AND (EXISTS ( SELECT 1
   FROM (public.agent_runs
     JOIN public.projects ON ((projects.id = agent_runs.project_id)))
  WHERE ((agent_runs.id = ab_test_assignments.agent_run_id) AND (projects.account_id = public.paid_current_account_id()))))))) WITH CHECK ((public.paid_tenant_bypass() OR ((EXISTS ( SELECT 1
   FROM (public.ab_tests
     JOIN public.prompts ON ((prompts.id = ab_tests.prompt_id)))
  WHERE ((ab_tests.id = ab_test_assignments.ab_test_id) AND (prompts.account_id = public.paid_current_account_id()) AND ((prompts.project_id IS NULL) OR (EXISTS ( SELECT 1
           FROM public.projects
          WHERE ((projects.id = prompts.project_id) AND (projects.account_id = public.paid_current_account_id())))))))) AND (EXISTS ( SELECT 1
   FROM (public.agent_runs
     JOIN public.projects ON ((projects.id = agent_runs.project_id)))
  WHERE ((agent_runs.id = ab_test_assignments.agent_run_id) AND (projects.account_id = public.paid_current_account_id())))))));


--
-- Name: ab_test_variants tenant_isolation_update; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY tenant_isolation_update ON public.ab_test_variants FOR UPDATE USING ((public.paid_tenant_bypass() OR (EXISTS ( SELECT 1
   FROM (public.ab_tests
     JOIN public.prompts ON ((prompts.id = ab_tests.prompt_id)))
  WHERE ((ab_tests.id = ab_test_variants.ab_test_id) AND (prompts.account_id = public.paid_current_account_id()) AND ((prompts.project_id IS NULL) OR (EXISTS ( SELECT 1
           FROM public.projects
          WHERE ((projects.id = prompts.project_id) AND (projects.account_id = public.paid_current_account_id())))))))))) WITH CHECK ((public.paid_tenant_bypass() OR (EXISTS ( SELECT 1
   FROM (public.ab_tests
     JOIN public.prompts ON ((prompts.id = ab_tests.prompt_id)))
  WHERE ((ab_tests.id = ab_test_variants.ab_test_id) AND (prompts.account_id = public.paid_current_account_id()) AND ((prompts.project_id IS NULL) OR (EXISTS ( SELECT 1
           FROM public.projects
          WHERE ((projects.id = prompts.project_id) AND (projects.account_id = public.paid_current_account_id()))))))))));


--
-- Name: ab_tests tenant_isolation_update; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY tenant_isolation_update ON public.ab_tests FOR UPDATE USING ((public.paid_tenant_bypass() OR (EXISTS ( SELECT 1
   FROM public.prompts
  WHERE ((prompts.id = ab_tests.prompt_id) AND (prompts.account_id = public.paid_current_account_id()) AND ((prompts.project_id IS NULL) OR (EXISTS ( SELECT 1
           FROM public.projects
          WHERE ((projects.id = prompts.project_id) AND (projects.account_id = public.paid_current_account_id())))))))))) WITH CHECK ((public.paid_tenant_bypass() OR (EXISTS ( SELECT 1
   FROM public.prompts
  WHERE ((prompts.id = ab_tests.prompt_id) AND (prompts.account_id = public.paid_current_account_id()) AND ((prompts.project_id IS NULL) OR (EXISTS ( SELECT 1
           FROM public.projects
          WHERE ((projects.id = prompts.project_id) AND (projects.account_id = public.paid_current_account_id()))))))))));


--
-- Name: prompt_versions tenant_isolation_update; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY tenant_isolation_update ON public.prompt_versions FOR UPDATE USING ((public.paid_tenant_bypass() OR (EXISTS ( SELECT 1
   FROM public.prompts
  WHERE ((prompts.id = prompt_versions.prompt_id) AND (prompts.account_id = public.paid_current_account_id()) AND ((prompts.project_id IS NULL) OR (EXISTS ( SELECT 1
           FROM public.projects
          WHERE ((projects.id = prompts.project_id) AND (projects.account_id = public.paid_current_account_id())))))))))) WITH CHECK ((public.paid_tenant_bypass() OR (EXISTS ( SELECT 1
   FROM public.prompts
  WHERE ((prompts.id = prompt_versions.prompt_id) AND (prompts.account_id = public.paid_current_account_id()) AND ((prompts.project_id IS NULL) OR (EXISTS ( SELECT 1
           FROM public.projects
          WHERE ((projects.id = prompts.project_id) AND (projects.account_id = public.paid_current_account_id()))))))))));


--
-- Name: prompts tenant_isolation_update; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY tenant_isolation_update ON public.prompts FOR UPDATE USING ((public.paid_tenant_bypass() OR ((account_id = public.paid_current_account_id()) AND ((project_id IS NULL) OR (EXISTS ( SELECT 1
   FROM public.projects
  WHERE ((projects.id = prompts.project_id) AND (projects.account_id = public.paid_current_account_id())))))))) WITH CHECK ((public.paid_tenant_bypass() OR ((account_id = public.paid_current_account_id()) AND ((project_id IS NULL) OR (EXISTS ( SELECT 1
   FROM public.projects
  WHERE ((projects.id = prompts.project_id) AND (projects.account_id = public.paid_current_account_id()))))))));


--
-- Name: style_guides tenant_isolation_update; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY tenant_isolation_update ON public.style_guides FOR UPDATE USING ((public.paid_tenant_bypass() OR ((account_id = public.paid_current_account_id()) AND ((project_id IS NULL) OR (EXISTS ( SELECT 1
   FROM public.projects
  WHERE ((projects.id = style_guides.project_id) AND (projects.account_id = public.paid_current_account_id())))))))) WITH CHECK ((public.paid_tenant_bypass() OR ((account_id = public.paid_current_account_id()) AND ((project_id IS NULL) OR (EXISTS ( SELECT 1
   FROM public.projects
  WHERE ((projects.id = style_guides.project_id) AND (projects.account_id = public.paid_current_account_id()))))))));


--
-- Name: tenant_settings; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.tenant_settings ENABLE ROW LEVEL SECURITY;

--
-- Name: token_usages; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.token_usages ENABLE ROW LEVEL SECURITY;

--
-- Name: tracker_configurations; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.tracker_configurations ENABLE ROW LEVEL SECURITY;

--
-- Name: user_settings; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.user_settings ENABLE ROW LEVEL SECURITY;

--
-- Name: users; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.users ENABLE ROW LEVEL SECURITY;

--
-- Name: workflow_states; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.workflow_states ENABLE ROW LEVEL SECURITY;

--
-- Name: worktrees; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.worktrees ENABLE ROW LEVEL SECURITY;

--
-- PostgreSQL database dump complete
--

SET search_path TO "$user", public;

INSERT INTO "schema_migrations" (version) VALUES
('20260427225726'),
('20260427223009'),
('20260427223003'),
('20260427143916'),
('20260427135718'),
('20260426231639'),
('20260426231603'),
('20260426231602'),
('20260426231558'),
('20260426114303'),
('20260426011810'),
('20260425225105'),
('20260425164954'),
('20260425114721'),
('20260425113212'),
('20260425061110'),
('20260425060000'),
('20260425052958'),
('20260425050134'),
('20260425045424'),
('20260423132408'),
('20260423130627'),
('20260421162139'),
('20260421162135'),
('20260421161445'),
('20260421155244'),
('20260421110831'),
('20260421083918'),
('20260421082052'),
('20260421080223'),
('20260421050706'),
('20260418233122'),
('20260418175716'),
('20260417204111'),
('20260417072332'),
('20260417061353'),
('20260417052710'),
('20260417052653'),
('20260417035334'),
('20260417031455'),
('20260417023648'),
('20260417023644'),
('20260417023639'),
('20260417023634'),
('20260417023631'),
('20260417023620'),
('20260417020855'),
('20260417020845'),
('20260417004908'),
('20260417004855'),
('20260417003646'),
('20260417002917'),
('20260417002757'),
('20260417002747'),
('20260416225105'),
('20260416225057'),
('20260416221827'),
('20260416221824'),
('20260416221700'),
('20260416221630'),
('20260416185458'),
('20260416185455'),
('20260416183113'),
('20260416173627'),
('20260416170203'),
('20260416170200'),
('20260416050235'),
('20260416020545'),
('20260415224710'),
('20260415224705'),
('20260415181029'),
('20260414154102'),
('20260414092756'),
('20260413193745'),
('20260413193654'),
('20260413191016'),
('20260413191015'),
('20260413190906'),
('20260412165456'),
('20260411163526'),
('20260411080344'),
('20260411022311'),
('20260411012931'),
('20260410204751'),
('20260409231400'),
('20260409184503'),
('20260408194803'),
('20260408170459'),
('20260408105320'),
('20260408042539'),
('20260408032317'),
('20260408004407'),
('20260407230341'),
('20260407230340'),
('20260407143249'),
('20260407081149'),
('20260407072915'),
('20260407071652'),
('20260407071634'),
('20260404161335'),
('20260404062147'),
('20260403062026'),
('20260403062020'),
('20260402162737'),
('20260402144014'),
('20260402144009'),
('20260402082402'),
('20260402081327'),
('20260402072439'),
('20260402063805'),
('20260402050141'),
('20260401135652'),
('20260401124101'),
('20260401121911'),
('20260331210524'),
('20260331121200'),
('20260331085647'),
('20260331085518'),
('20260331004430'),
('20260331004223'),
('20260329230136'),
('20260329230135'),
('20260329170336'),
('20260329170311'),
('20260329155927'),
('20260329095600'),
('20260328194042'),
('20260328151609'),
('20260328101939'),
('20260328101928'),
('20260328060002'),
('20260328060001'),
('20260328060000'),
('20260328055556'),
('20260328002528'),
('20260328002514'),
('20260328002231'),
('20260327215948'),
('20260327215947'),
('20260327015930'),
('20260327000516'),
('20260326180754'),
('20260326070000'),
('20260326060000'),
('20260326050122'),
('20260326044241'),
('20260326012903'),
('20260326011329'),
('20260326005130'),
('20260325233029'),
('20260325230902'),
('20260325230858'),
('20260325230853'),
('20260325230847'),
('20260325230842'),
('20260325162327'),
('20260325120000'),
('20260325081039'),
('20260325080816'),
('20260325080812'),
('20260325074842'),
('20260325040417'),
('20260325034844'),
('20260324023748'),
('20260323000000'),
('20260322000000'),
('20260320000000'),
('20260318000000'),
('20260314000002'),
('20260314000001'),
('20260310200000'),
('20260309200000'),
('20260308200003'),
('20260308200002'),
('20260308200000'),
('20260308100000'),
('20260308000001'),
('20260308000000'),
('20260307140000'),
('20260307130000'),
('20260307120000'),
('20260307010138'),
('20260306120000'),
('20260304100002'),
('20260304100001'),
('20260304100000'),
('20260304000000'),
('20260302090000'),
('20260301210000'),
('20260301205144'),
('20260301000000'),
('20260228130000'),
('20260228120000'),
('20260228091506'),
('20260226120000'),
('20260225100000'),
('20260223205823'),
('20260223000001'),
('20260222020000'),
('20260222010000'),
('20260221000002'),
('20260221000001'),
('20260220030250'),
('20260219051249'),
('20260214070851'),
('20260214070737'),
('20260214015307'),
('20260214012342'),
('20260208130000'),
('20260208120000'),
('20260208100000'),
('20260208063656'),
('20260208005438'),
('20260201042103'),
('20260129230315'),
('20260129222211'),
('20260129214933'),
('20260129214932'),
('20260129043009'),
('20260129031603'),
('20260129022148'),
('20260129013551'),
('20260129004830'),
('20260128161602'),
('20260128034216'),
('20260128004342'),
('20260128004305'),
('20260127154444');

