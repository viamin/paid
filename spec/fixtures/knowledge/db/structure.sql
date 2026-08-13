SET statement_timeout = 0;
SET lock_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: users; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.users (
    id bigint NOT NULL,
    email character varying NOT NULL,
    name character varying,
    encrypted_password character varying NOT NULL,
    admin boolean DEFAULT false,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);

--
-- Name: posts; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.posts (
    id bigint NOT NULL,
    title character varying NOT NULL,
    body text,
    user_id bigint NOT NULL,
    status character varying DEFAULT 'draft'::character varying,
    published_at timestamp(6) without time zone,
    views_count integer DEFAULT 0 NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);

--
-- Name: comments; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.comments (
    id bigint NOT NULL,
    body text NOT NULL,
    post_id bigint NOT NULL,
    user_id bigint NOT NULL,
    commentable_type character varying,
    commentable_id bigint,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);

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
-- Name: schema_migrations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.schema_migrations (
    version character varying NOT NULL
);

--
-- Name: tags; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.tags (
    id bigint NOT NULL,
    name character varying NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);

--
-- Indexes
--

CREATE UNIQUE INDEX index_users_on_email ON public.users USING btree (email);

CREATE INDEX index_posts_on_user_id ON public.posts USING btree (user_id);

CREATE INDEX index_posts_on_status_and_published_at ON public.posts USING btree (status, published_at);

CREATE INDEX index_comments_on_commentable ON public.comments USING btree (commentable_type, commentable_id);

CREATE INDEX index_comments_on_post_id ON public.comments USING btree (post_id);

CREATE INDEX index_comments_on_user_id ON public.comments USING btree (user_id);

CREATE UNIQUE INDEX index_tags_on_name ON public.tags USING btree (name);

--
-- Foreign Keys
--

ALTER TABLE ONLY public.posts
    ADD CONSTRAINT fk_rails_posts_user FOREIGN KEY (user_id) REFERENCES public.users(id);

ALTER TABLE ONLY public.comments
    ADD CONSTRAINT fk_rails_comments_post FOREIGN KEY (post_id) REFERENCES public.posts(id);

ALTER TABLE ONLY public.comments
    ADD CONSTRAINT fk_rails_comments_user FOREIGN KEY (user_id) REFERENCES public.users(id);
