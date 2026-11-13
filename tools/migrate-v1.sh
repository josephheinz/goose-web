#!/bin/sh
# Moves an app from gweb v0.7 to v1.0. Edits the files in place; run it on a clean tree and read the diff.
#
#   sh tools/migrate-v1.sh [DIR or FILE ...]     (default: .)
#
# Rewrites, in *.goose, *.html, *.gshtml and *.md (the generated-folder names .gooseweb* too):
#   - renamed functions: gweb::write and gweb::end are stream_write and stream_end, gweb::send is socket_send,
#     debug, info, warn and error are log_debug, log_info, log_warn and log_error, field, log, emit and render are
#     log_field, log_event, log_emit and log_render, count and gauge are metric_count and metric_gauge, and the
#     five-argument gweb::form_int (a form decoder) is gweb::form_i64;
#   - names that were never documented (generated-code plumbing and module helpers): gweb::new_ctx is gweb::_new_ctx.
# Rewrites, in .gitignore, .dockerignore, Dockerfiles, scripts, units, compose files, CI files, .env files and *.md:
#   - the generated folders .gooseweb, .gooseweb.dev, .gooseweb.test, .gooseweb.lsp, .gooseweb.uploads and the others are
#     .gweb, .gweb.dev, ...;
#   - the server flag --log (the access log) is --access-log.
#
# What it cannot do, and prints a reminder about when it finds the code:
#   - behind a TLS proxy, set GWEB_TRUST_PROXY=1: X-Forwarded-Proto counts only then;
#   - gweb::cookie_or and gweb::cookie_int now percent-decode, and cookie_or returns an owned value (u8[>..]), so a Props
#     field that holds it is u8[>..] (the last field) or u8[..N], not a slice; gweb::cookie_raw reads the bytes as sent;
#   - gweb::markdown, send_file and the form helpers keep their calls; a Goose test that built a gweb::Config sets access_log.
# Rename the same things wherever else you keep them (a host's environment, CI, a Procfile). Needs perl.
set -eu
[ $# -eq 0 ] && set -- .

# 1. Goose sources and docs: function names.
find "$@" -type f \( -name '*.goose' -o -name '*.html' -o -name '*.gshtml' -o -name '*.md' \) \
  -not -path '*/.gooseweb*' -not -path '*/.gweb*' -not -path '*/.git/*' -print0 |
xargs -0 perl -pi -e '
  BEGIN {
    $alt = join "|", qw(
    access_line add_excerpt add_excerpts all_digits all_in append_id apply_cookies apply_redirect apply_security
    b64_value begin_request builtin_page cache_etag cache_num cache_put cache_serve cache_store
    cacheable_request config_from config_from_args content_length cors_origin_allowed cors_overflow crash_info
    csrf_cookie_name csrf_ok csrf_valid default_config default_workers dev_detail dev_error_script dev_inject
    dev_mode dev_secret dev_status digit encode_session env_csp env_name_byte env_name_start env_nonneg
    env_positive environment epoch error_json error_start fail_login field_text file_base file_disposition
    file_miss fragment_index fragment_reply has_token hub_of inflight_conn inflight_init inflight_pending
    inflight_phase inflight_phase_of inflight_release inflight_route inflight_route_of inflight_set_why
    is_multipart issue_session jar_get jar_put jar_update job_abandon job_ctx job_done job_push job_take
    jobs_init jobs_queued jobs_stop jr_bool jr_enum jr_int jr_text json_escape_byte json_escape_max key_valid
    lang_is lang_part lastmod_ok level_from_name level_name level_num load_env_file load_env_files
    load_env_files_in log_configure log_message log_write login_at lower_is make_nonce map_source max_age_zero
    md_alnum md_atx md_blank md_cut md_dest md_fence md_hr md_inline md_lead md_marker md_punct md_skip_cols
    md_space md_url_kind meta_url method_index method_not_allowed multipart_begin multipart_fail new_ctx
    new_error new_part new_schedules no_hub no_params no_static not_modified now_s old_env_names ops_init
    ops_shutdown options origin_authority owner_call_fd owner_channels owner_leave owner_loop param_value
    parse_env_line parse_multipart parse_part_head parse_password_hash parse_q parse_secret parse_session_value
    part_abort part_begin part_data part_end password_hash_iter path_byte path_stop path_valid pct_append
    pct_encode pick_locale plain_500 plain_not_found plural_index prepare_uploads probe push_field
    push_server_span rate_check rate_refuse rate_take_at read_window render_meta request_id_valid
    require_login_api_at require_login_at respond robots_begin robots_reply route_name run_worker schedule_cron
    schedule_every schedule_refused second_part send_not_modified send_static session_at session_cookie_name
    session_cookie_opts session_set_data_at set_param set_rest set_topic signed_mac sitemap_init sitemap_path_ok
    sitemap_reply slot_allows sniff_bytes split split_lines split_on strip_port tag_by_lang tag_exact test_send
    text_needs_quote text_value tok token_equal utf8_cut valid_log_format valid_log_level vf_bool vf_enum
    vf_group_close vf_group_open vf_int vf_item_close vf_item_open vf_label vf_list_close vf_list_open vf_tail
    vf_text vm_field vm_slot vname vp_bool vp_count vp_enum vp_int vp_text worker_end
    );
  }
  s/\.gooseweb/.gweb/g;
  s/\bgweb::write\b/gweb::stream_write/g;
  s/\bgweb::end\b/gweb::stream_end/g;
  s/\bgweb::send\b/gweb::socket_send/g;
  s/\bgweb::(debug|info|warn|error)\b/gweb::log_$1/g;
  s/\bgweb::field\b/gweb::log_field/g;
  s/\bgweb::emit\b/gweb::log_emit/g;
  s/\bgweb::render\b/gweb::log_render/g;
  s/\bgweb::log\b/gweb::log_event/g;
  s/\bgweb::count\b/gweb::metric_count/g;
  s/\bgweb::gauge\b/gweb::metric_gauge/g;
  s/\bgweb::form_int\(([^,()]+),([^,()]+),([^,()]+),([^,()]+),([^,()]+)\)/gweb::form_i64($1,$2,$3,$4,$5)/g;
  s/\bgweb::($alt)\b/gweb::_$1/g;
'

# 2. Paths and flags, wherever a project writes them down.
find "$@" -type f \( -name '.gitignore' -o -name '.dockerignore' -o -name '.env*' -o -name 'Dockerfile*' -o -name '*.sh' \
  -o -name '*.service' -o -name '*.socket' -o -name '*compose*.y*ml' -o -name '*.yml' -o -name '*.yaml' -o -name 'Procfile' \
  -o -name 'Makefile' -o -name '*.toml' -o -name '*.md' \) \
  -not -path '*/.gooseweb*' -not -path '*/.gweb*' -not -path '*/.git/*' -print0 |
xargs -0 perl -pi -e '
  s/\.gooseweb/.gweb/g;
  s/(?<![-\w])--log(?![-\w=])/--access-log/g;
'

# 3. Reminders.
note() { echo "migrate-v1: $1" >&2; }
if grep -rIl --include='*.goose' --include='*.html' --include='*.gshtml' 'gweb::cookie_or\|gweb::cookie_int' "$@" 2>/dev/null | grep -q .; then
  note "gweb::cookie_or and cookie_int now percent-decode; cookie_or returns an owned u8[>..]. Check where its result is stored (use gweb::cookie_raw for the old bytes)."
fi
if grep -rIl 'X-Forwarded-Proto\|reverse_proxy\|proxy_pass' "$@" 2>/dev/null | grep -q .; then
  note "this project mentions a proxy. Behind a TLS proxy set GWEB_TRUST_PROXY=1, or session and CSRF cookies lose __Host- and Secure."
fi
