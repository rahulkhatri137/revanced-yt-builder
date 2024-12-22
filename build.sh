#!/usr/bin/env bash

set -euo pipefail
trap "rm -rf temp/*tmp.* temp/*/*tmp.*; exit 130" INT

source action.sh
: >build.md

vtf() { if ! isoneof "${1}" "true" "false"; then abort "ERROR: '${1}' is not a valid option for '${2}': only true or false is allowed"; fi; }

toml_prep "$(cat 2>/dev/null "${1:-config.toml}")" || abort "could not find config file '${1:-config.toml}'\n\tUsage: $0 <config.toml>"

mkdir -p $TEMP_DIR $BUILD_DIR

#check_deps
jq --version >/dev/null || abort "\`jq\` is not installed. install it with 'apt install jq' or equivalent"
java --version >/dev/null || abort "\`openjdk 17\` is not installed. install it with 'apt install openjdk-17-jre-headless' or equivalent"
# --
HTMLQ="${TEMP_DIR}/htmlq"
if [ ! -f "$HTMLQ" ]; then
	req "https://github.com/mgdm/htmlq/releases/latest/download/htmlq-x86_64-linux.tar.gz" "${TEMP_DIR}/htmlq.tar.gz"
	tar -xf "${TEMP_DIR}/htmlq.tar.gz" -C "$TEMP_DIR"
	rm "${TEMP_DIR}/htmlq.tar.gz"
fi

log "**Changelog**: [ReVanced-Extended](https://github.com/inotia00/revanced-patches/releases/) | [Revanced](https://github.com/revanced/revanced-patches/releases/)"
log "**Note**: _[Revanced GmsCore](https://github.com/Revanced/GmsCore/releases/latest) must be installed!_"
log "## **Only for *arm64-v8a* devices**\n"

set_prebuilts() {
	local patches_src=$1 cli_src=$2
	local patches_dir=${patches_src%/*}
	local cli_dir=${cli_src%/*}

	app_args[cli]=$(find "${TEMP_DIR}/${cli_dir//[^[:alnum:]]/}-rv" -name "revanced-cli-*.jar" -type f -print -quit 2>/dev/null) && [ "${app_args[cli]}" ] || return 1
	app_args[ptjar]=$(find "${TEMP_DIR}/${patches_dir//[^[:alnum:]]/}-rv" -name "patches-*.rvp" -type f -print -quit 2>/dev/null) && [ "${app_args[ptjar]}" ] || return 1
}

build_rvx() {
	build_rv "$(declare -p app_args)" &
}

for table_name in $(toml_get_table_names); do
	if [ -z "$table_name" ]; then continue; fi
	t=$(toml_get_table "$table_name")
	enabled=$(toml_get "$t" enabled) && vtf "$enabled" "enabled" || enabled=true
	if [ "$enabled" = false ]; then continue; fi

	declare -A app_args
	patches_src=$(toml_get "$t" patches-source) || patches_src=""
	cli_src=$(toml_get "$t" cli-source) || cli_src=""
	if ! set_prebuilts "$patches_src" "$cli_src"; then
		read -r rv_cli_jar rv_patches_jar \
			<<<"$(get_prebuilts "$patches_src" "$cli_src")"
		app_args[cli]=$rv_cli_jar
		app_args[ptjar]=$rv_patches_jar
	fi
	app_args[rv_brand]=$(toml_get "$t" rv-brand) || app_args[rv_brand]="ReVanced"

	app_args[excluded_patches]=$(toml_get "$t" excluded-patches) || app_args[excluded_patches]=""
	app_args[included_patches]=$(toml_get "$t" included-patches) || app_args[included_patches]=""
	app_args[exclusive_patches]=$(toml_get "$t" exclusive-patches) && vtf "${app_args[exclusive_patches]}" "exclusive-patches" || app_args[exclusive_patches]=false
	app_args[version]=$(toml_get "$t" version) || app_args[version]="auto"
	app_args[app_name]=$(toml_get "$t" app-name) || app_args[app_name]=$table_name
	app_args[table]=$table_name
	app_args[build_mode]=$(toml_get "$t" build-mode) && {
		if ! isoneof "${app_args[build_mode]}" apk; then
			abort "ERROR: build-mode '${app_args[build_mode]}' is not a valid option for '${table_name}': only 'apk' is allowed"
		fi
	} || app_args[build_mode]=apk
	app_args[apkmirror_dlurl]=$(toml_get "$t" apkmirror-dlurl) && {
		app_args[apkmirror_dlurl]=${app_args[apkmirror_dlurl]%/}
		app_args[dl_from]=apkmirror
	} || app_args[apkmirror_dlurl]=""
	if [ -z "${app_args[dl_from]:-}" ]; then abort "ERROR: no 'apkmirror_dlurl' option was set for '$table_name'."; fi
	app_args[arch]=$(toml_get "$t" apkmirror-arch) && {
		if ! isoneof "${app_args[arch]}" universal arm64-v8a arm-v7a; then
			abort "ERROR: arch '${app_args[arch]}' is not a valid option for '${table_name}': only 'universal', 'arm64-v8a', 'arm-v7a' is allowed"
		fi
	} || app_args[arch]="universal"
	app_args[dpi]=$(toml_get "$t" apkmirror-dpi) || app_args[dpi]="nodpi"
	table_name_f=${table_name,,}
	table_name_f=${table_name_f// /-}

	build_rvx
done
wait
rm -rf temp/tmp.*
if [ -z "$(ls -A1 ${BUILD_DIR})" ]; then abort "All builds failed."; fi
log "$(cat $TEMP_DIR/*-rv/changelog.md)"
log "ReVanced by @ReVanced"
log "ReVanced-Extended by @inotia00"
pr "Done"
