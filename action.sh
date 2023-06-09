#!/usr/bin/env bash

TEMP_DIR="temp"
BUILD_DIR="build"

if [ "${TOKEN:-}" ]; then GH_HEADER="Authorization: token ${TOKEN}"; else GH_HEADER=; fi
NEXT_VER_CODE=${NEXT_VER_CODE:-$(date +'%Y%m%d')}
REBUILD=false
OS=$(uname -o)

# -------------------- json/toml --------------------
json_get() { grep -o "\"${1}\":[^\"]*\"[^\"]*\"" | sed -E 's/".*".*"(.*)"/\1/'; }
toml_prep() { __TOML__=$(tr -d '\t\r' <<<"$1" | tr "'" '"' | grep -o '^[^#]*' | grep -v '^$' | sed -r 's/(\".*\")|\s*/\1/g; 1i []'); }
toml_get_table_names() {
	local tn
	tn=$(grep -x '\[.*\]' <<<"$__TOML__" | tr -d '[]') || return 1
	if [ "$(sort <<<"$tn" | uniq -u | wc -l)" != "$(wc -l <<<"$tn")" ]; then
		abort "ERROR: Duplicate tables in TOML"
	fi
	echo "$tn"
}
toml_get_table() { sed -n "/\[${1}]/,/^\[.*]$/p" <<<"$__TOML__"; }
toml_get() {
	local table=$1 key=$2 val
	val=$(grep -m 1 "^${key}=" <<<"$table") && sed -e "s/^\"//; s/\"$//" <<<"${val#*=}"
}
# ---------------------------------------------------

pr() { echo -e "\033[0;32m[+] ${1}\033[0m"; }
epr() {
	echo >&2 -e "\033[0;31m[-] ${1}\033[0m"
	if [ "${GITHUB_REPOSITORY:-}" ]; then echo -e "::error::action.sh [-] ${1}\n"; fi
}
abort() {
	epr "ABORT: ${1:-}"
	exit 1
}

get_prebuilts() {
	pr "Getting prebuilts"
	local rv_cli_url rv_integrations_url rv_patches rv_patches_changelog rv_patches_dl rv_patches_url rv_integrations_rel rv_patches_rel
	rv_cli_url=$(gh_req "https://api.github.com/repos/inotia00/revanced-cli/releases/latest" - | json_get 'browser_download_url') || return 1
	RV_CLI_JAR="${PREBUILTS_DIR}/${rv_cli_url##*/}"
	log "**CLI**: _${rv_cli_url##*/}_"
        rv_integrations_rel="https://api.github.com/repos/inotia00/revanced-integrations/releases/latest"
	rv_patches_rel="https://api.github.com/repos/inotia00/revanced-patches/releases/latest"
	rv_integrations_url=$(gh_req "$rv_integrations_rel" - | json_get 'browser_download_url')
	RV_INTEGRATIONS_APK="${PREBUILTS_DIR}/${rv_integrations_url##*/}"
	log "**Integrations**: _${rv_integrations_url##*/}_"

	rv_patches=$(gh_req "$rv_patches_rel" -)
	rv_patches_changelog=$(json_get 'body' <<<"$rv_patches" | sed 's/\(\\n\)\+/\\n/g')
	rv_patches_dl=$(json_get 'browser_download_url' <<<"$rv_patches")
	RV_PATCHES_JSON="${PREBUILTS_DIR}/patches-$(json_get 'tag_name' <<<"$rv_patches").json"
	rv_patches_url=$(grep 'jar' <<<"$rv_patches_dl")
	RV_PATCHES_JAR="${PREBUILTS_DIR}/${rv_patches_url##*/}"
	[ -f "$RV_PATCHES_JAR" ] || REBUILD=true
	log "**Patches**: _${rv_patches_url##*/}_\n"
        log "**Changelog**: [Here](https://github.com/inotia00/revanced-patches/releases/)\n"

	dl_if_dne "$RV_CLI_JAR" "$rv_cli_url"
	dl_if_dne "$RV_INTEGRATIONS_APK" "$rv_integrations_url"
	dl_if_dne "$RV_PATCHES_JAR" "$rv_patches_url"
	dl_if_dne "$RV_PATCHES_JSON" "$(grep 'json' <<<"$rv_patches_dl")"

	HTMLQ="${TEMP_DIR}/htmlq"
	if [ ! -f "${TEMP_DIR}/htmlq" ]; then
         	req "https://github.com/mgdm/htmlq/releases/latest/download/htmlq-x86_64-linux.tar.gz" "${TEMP_DIR}/htmlq.tar.gz"
		tar -xf "${TEMP_DIR}/htmlq.tar.gz" -C "$TEMP_DIR"
		rm "${TEMP_DIR}/htmlq.tar.gz"
	fi
}

set_prebuilts() {
	[ -d "$PREBUILTS_DIR" ] || abort "${PREBUILTS_DIR} directory could not be found"
	RV_CLI_JAR=$(find "$PREBUILTS_DIR" -maxdepth 1 -name "revanced-cli-*.jar" | tail -n1)
	[ "$RV_CLI_JAR" ] || abort "revanced cli not found"
	log "CLI: ${RV_CLI_JAR#"$PREBUILTS_DIR/"}"
	RV_INTEGRATIONS_APK=$(find "$PREBUILTS_DIR" -maxdepth 1 -name "revanced-integrations-*.apk" | tail -n1)
	[ "$RV_INTEGRATIONS_APK" ] || abort "revanced integrations not found"
	log "Integrations: ${RV_INTEGRATIONS_APK#"$PREBUILTS_DIR/"}"
	RV_PATCHES_JAR=$(find "$PREBUILTS_DIR" -maxdepth 1 -name "revanced-patches-*.jar" | tail -n1)
	[ "$RV_PATCHES_JAR" ] || abort "revanced patches not found"
	log "Patches: ${RV_PATCHES_JAR#"$PREBUILTS_DIR/"}"
	RV_PATCHES_JSON=$(find "$PREBUILTS_DIR" -maxdepth 1 -name "patches-*.json" | tail -n1)
	[ "$RV_PATCHES_JSON" ] || abort "patches.json not found"
	HTMLQ="${TEMP_DIR}/htmlq"
}

_req() {
	if [ "$2" = - ]; then
		wget -nv -O "$2" --header="$3" "$1"
	else
		local dlp
		dlp="$(dirname "$2")/tmp.$(basename "$2")"
		wget -nv -O "$dlp" --header="$3" "$1"
		mv -f "$dlp" "$2"
	fi
}
req() { _req "$1" "$2" "User-Agent: Mozilla/5.0 (X11; Linux x86_64; rv:108.0) Gecko/20100101 Firefox/108.0"; }
gh_req() { _req "$1" "$2" "$GH_HEADER"; }

log() { echo -e "$1  " >>build.md; }
get_largest_ver() {
	local vers m
	vers=$(tee)
	m=$(head -1 <<<"$vers")
	if ! semver_validate "$m"; then echo "$m"; else sort -rV <<<"$vers" | head -1; fi
}
semver_validate() {
	local a="${1%-*}"
	local ac="${a//[.0-9]/}"
	[ ${#ac} = 0 ]
}
get_patch_last_supported_ver() {
        jq -r ".[]
		| select(.compatiblePackages[].name==\"${1}\" and .excluded==false)
		| .compatiblePackages[].versions" "$RV_PATCHES_JSON" |
	tr -d ' ,\t[]"' | grep -v '^$' | sort | uniq -c | sort -nr | head -1 | xargs | cut -d' ' -f2 || return 1
}

dl_if_dne() {
	if [ ! -f "$1" ]; then
		pr "Getting '$1' from '$2'"
		req "$2" "$1"
	fi
}

isoneof() {
	local i=$1 v
	shift
	for v; do [ "$v" = "$i" ] && return 0; done
	return 1
}

# -------------------- apkmirror --------------------
dl_apkmirror() {
	local url=$1 version=${2// /-} output=$3 apkorbundle=$4 arch=$5 dpi=$6
	[ "${DRYRUN:-}" ] && {
		echo >"$output"
		return 0
	}
	local resp node app_table dlurl=""
	[ "$arch" = universal ] && apparch=(universal noarch 'arm64-v8a + armeabi-v7a') || apparch=("$arch")
	url="${url}/${url##*/}-${version//./-}-release/"
	resp=$(req "$url" -) || return 1
	for ((n = 2; n < 40; n++)); do
		node=$($HTMLQ "div.table-row:nth-child($n)" -r "span:nth-child(n+3)" <<<"$resp")
		if [ -z "$node" ]; then break; fi
		app_table=$($HTMLQ --text --ignore-whitespace <<<"$node")
		if [ "$(sed -n 3p <<<"$app_table")" = "$apkorbundle" ] && { [ "$apkorbundle" = BUNDLE ] ||
			{ [ "$apkorbundle" = APK ] && [ "$(sed -n 6p <<<"$app_table")" = "$dpi" ] &&
				isoneof "$(sed -n 4p <<<"$app_table")" "${apparch[@]}"; }; }; then
			dlurl=https://www.apkmirror.com$($HTMLQ --attribute href "div:nth-child(1) > a:nth-child(1)" <<<"$node")
			break
		fi
	done
	[ -z "$dlurl" ] && return 1
	url="https://www.apkmirror.com$(req "$dlurl" - | sed -n 's;.*href="\(.*key=[^"]*\)">.*;\1;p' | tail -1)"
	if [ "$apkorbundle" = BUNDLE ] && [[ "$url" != *"&forcebaseapk=true" ]]; then url="${url}&forcebaseapk=true"; fi
	url="https://www.apkmirror.com$(req "$url" - | sed -n 's;.*href="\(.*key=[^"]*\)">.*;\1;p')"
	req "$url" "$output"
}
get_apkmirror_vers() {
	local apkmirror_category=$1 allow_alpha_version=$2
	local vers apkm_resp
	apkm_resp=$(req "https://www.apkmirror.com/uploads/?appcategory=${apkmirror_category}" -)
	# apkm_name=$(echo "$apkm_resp" | sed -n 's;.*Latest \(.*\) Uploads.*;\1;p')
	vers=$(sed -n 's;.*Version:</span><span class="infoSlide-value">\(.*\) </span>.*;\1;p' <<<"$apkm_resp")
	if [ "$allow_alpha_version" = false ]; then
		local IFS=$'\n'
		vers=$(grep -iv "\(beta\|alpha\)" <<<"$vers")
		local v r_vers=()
		for v in $vers; do
			grep -iq "${v} \(beta\|alpha\)" <<<"$apkm_resp" || r_vers+=("$v")
		done
		echo "${r_vers[*]}"
	else
		echo "$vers"
	fi
}
get_apkmirror_pkg_name() { req "$1" - | sed -n 's;.*id=\(.*\)" class="accent_color.*;\1;p'; }
# --------------------------------------------------

patch_apk() {
	local stock_input=$1 patched_apk=$2 patcher_args=$3
	declare -r tdir=$(mktemp -d -p $TEMP_DIR)
	local cmd="java -jar $RV_CLI_JAR --rip-lib x86_64 --rip-lib x86 --temp-dir=$tdir -c -a $stock_input -o $patched_apk -b $RV_PATCHES_JAR --keystore=revanced.keystore $patcher_args"
	pr "$cmd"
	if [ "${DRYRUN:-}" = true ]; then
		cp -f "$stock_input" "$patched_apk"
	else
		eval "$cmd"
	fi
	[ -f "$patched_apk" ]
}

build_rv() {
	local -n args=$1
	local version build_mode_arr pkg_name uptwod_resp
	local mode_arg=${args[build_mode]} version_mode=${args[version]}
	local app_name=${args[app_name]}
	local app_name_l=${app_name,,}
	local dl_from=${args[dl_from]}
	local arch=${args[arch]}
	local p_patcher_args=()
	p_patcher_args+=("$(join_args "${args[excluded_patches]}" -e) $(join_args "${args[included_patches]}" -i)")
	[ "${args[exclusive_patches]}" = true ] && p_patcher_args+=("--exclusive")

	if [ "$dl_from" = apkmirror ]; then
		pkg_name=$(get_apkmirror_pkg_name "${args[apkmirror_dlurl]}")
	fi

	local get_latest_ver=false
	if [ "$version_mode" = auto ]; then
		version=$(
			get_patch_last_supported_ver "$pkg_name" \
				"${args[included_patches]}" "${args[excluded_patches]}" "${args[exclusive_patches]}"
		) || get_latest_ver=true
	fi
	if [ $get_latest_ver = true ]; then
		local apkmvers
		if [ "$dl_from" = apkmirror ]; then
			apkmvers=$(get_apkmirror_vers "${args[apkmirror_dlurl]##*/}" "false")
			version=$(get_largest_ver <<<"$apkmvers") || version=$(head -1 <<<"$apkmvers")
		fi
	fi
	if [ -z "$version" ]; then
		epr "empty version, not building ${app_name}."
		return 0
	fi
	pr "Choosing version '${version}' (${app_name})"
	local version_f=${version// /}
	local stock_apk="${TEMP_DIR}/${pkg_name}-${version_f}-${arch}.apk"
	if [ ! -f "$stock_apk" ]; then
		if [ "$dl_from" = apkmirror ]; then
			pr "Downloading '${app_name}' from APKMirror"
			local apkm_arch
			if [ "$arch" = "all" ]; then
				apkm_arch="universal"
			elif [ "$arch" = "arm64-v8a" ]; then
				apkm_arch="arm64-v8a"
			elif [ "$arch" = "arm-v7a" ]; then
				apkm_arch="armeabi-v7a"
			fi
			if ! dl_apkmirror "${args[apkmirror_dlurl]}" "$version" "$stock_apk" APK "$apkm_arch" "${args[dpi]}"; then
				epr "ERROR: Could not find any release of '${app_name}' with version '${version}', arch '${apkm_arch}' and dpi '${args[dpi]}' from APKMirror"
				return 0
			fi
		fi
	fi
	grep -q "${app_name}:" build.md || log "${app_name}: ${version}"
	if [ "${args[merge_integrations]}" = true ]; then
		p_patcher_args+=("-m ${RV_INTEGRATIONS_APK}")
	fi

	local microg_patch
	microg_patch=$(jq -r ".[] | select(.compatiblePackages[].name==\"${pkg_name}\") | .name" "$RV_PATCHES_JSON" | grep -F microg || :)
	if [ "$microg_patch" ]; then
		p_patcher_args=("${p_patcher_args[@]//-[ei] ${microg_patch}/}")
	fi

	local stock_bundle_apk="${TEMP_DIR}/${pkg_name}-${version_f}-${arch}-bundle.apk"
	local is_bundle=false
	if [ "$mode_arg" = apk ]; then
		build_mode_arr=(apk)
	fi
	local patcher_args patched_apk build_mode
	for build_mode in "${build_mode_arr[@]}"; do
		patcher_args=("${p_patcher_args[@]}")
		pr "Building '${app_name}' (${arch}) in '$build_mode' mode"
		if [ "$microg_patch" ]; then
			patched_apk="${TEMP_DIR}/${app_name_l}-${RV_BRAND_F}-${version_f}-${arch}-${build_mode}.apk"
			if [ "$build_mode" = apk ]; then
				patcher_args+=("-i ${microg_patch}")
			fi
		else
			patched_apk="${TEMP_DIR}/${app_name_l}-${RV_BRAND_F}-${version_f}-${arch}.apk"
		fi
		if [ ! -f "$patched_apk" ] || [ "$REBUILD" = true ]; then
			if ! patch_apk "$stock_apk" "$patched_apk" "${patcher_args[*]}"; then
				pr "Building '${app_name}' failed!"
				return 0
			fi
		fi
		if [ "$build_mode" = apk ]; then
			local apk_output="${BUILD_DIR}/${app_name_l}-${RV_BRAND_F}-v${version_f}-${arch}.apk"
			cp -f "$patched_apk" "$apk_output"
			pr "Built ${app_name} (${arch}) (non-root): '${apk_output}'"
			continue
		fi
		pr "Built ${app_name} (${arch})"
	done
}

list_args() { tr -d '\t\r' <<<"$1" | tr ' ' '\n' | grep -v '^$' || :; }
join_args() { list_args "$1" | sed "s/^/${2} /" | paste -sd " " - || :; }
