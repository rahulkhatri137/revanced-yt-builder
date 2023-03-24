#!/usr/bin/env bash

source action.sh

: >build.md

toml_prep "$(cat 2>/dev/null "${1:-config.toml}")" || abort "could not find config file '${1}'"

# -- Main config --
main_config_t=$(toml_get_table "")
RV_BRAND="ReVanced Extended"
RV_BRAND_F=${RV_BRAND,,}
RV_BRAND_F=${RV_BRAND_F// /-}
PREBUILTS_DIR="${TEMP_DIR}/tools-${RV_BRAND_F}"
mkdir -p "$BUILD_DIR" "$PREBUILTS_DIR"
# -- Main config --

if [ "${NOSET:-}" = true ]; then set_prebuilts; else get_prebuilts || set_prebuilts; fi
jq --version >/dev/null || abort "\`jq\` is not installed. install it with 'apt install jq' or equivalent"

log "**App Versions:**"
for table_name in $(toml_get_table_names); do
	if [ -z "$table_name" ]; then continue; fi
	t=$(toml_get_table "$table_name")
	enabled=$(toml_get "$t" enabled) || enabled=true
	if [ "$enabled" = false ]; then continue; fi
	declare -A app_args
	app_args[excluded_patches]=$(toml_get "$t" excluded-patches) || app_args[excluded_patches]=""
	app_args[included_patches]=$(toml_get "$t" included-patches) || app_args[included_patches]=""
	app_args[exclusive_patches]=$(toml_get "$t" exclusive-patches) && vtf "${app_args[exclusive_patches]}" "exclusive-patches" || app_args[exclusive_patches]=false
	app_args[version]=$(toml_get "$t" version) || app_args[version]="auto"
	app_args[app_name]=$(toml_get "$t" app-name) || app_args[app_name]=$table_name
	app_args[build_mode]=$(toml_get "$t" build-mode) || app_args[build_mode]=apk
	app_args[apkmirror_dlurl]=$(toml_get "$t" apkmirror-dlurl) && {
		app_args[apkmirror_dlurl]=${app_args[apkmirror_dlurl]%/}
		app_args[dl_from]=apkmirror
	} || app_args[apkmirror_dlurl]=""
	if [ -z "${app_args[dl_from]:-}" ]; then
		abort "ERROR: no Download URL."
	fi
	app_args[arch]=$(toml_get "$t" arch) || app_args[arch]="all"
	app_args[merge_integrations]=$(toml_get "$t" merge-integrations) || app_args[merge_integrations]=true
	app_args[dpi]=$(toml_get "$t" dpi) || app_args[dpi]="nodpi"

	build_rv app_args &
done
wait
rm -rf temp/tmp.*
if [ -z "$(ls -A1 ${BUILD_DIR})" ]; then abort "All builds failed."; fi
pr "Done"
