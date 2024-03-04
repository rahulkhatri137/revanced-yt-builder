#!/usr/bin/env bash

TEMP_DIR="temp"
BUILD_DIR="build"

if [ "${GITHUB_TOKEN:-}" ]; then GH_HEADER="Authorization: token ${GITHUB_TOKEN}"; else GH_HEADER=; fi
NEXT_VER_CODE=${NEXT_VER_CODE:-$(date +'%Y%m%d')}
REBUILD=${REBUILD:-false}
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
	local integrations_src=$1 patches_src=$2 cli_src=$3
	local patches_dir=${patches_src%/*}
	patches_dir=${TEMP_DIR}/${patches_dir//[^[:alnum:]]/}-rv
	local integrations_dir=${integrations_src%/*}
	integrations_dir=${TEMP_DIR}/${integrations_dir//[^[:alnum:]]/}-rv
	local cli_dir=${cli_src%/*}
	cli_dir=${TEMP_DIR}/${cli_dir//[^[:alnum:]]/}-rv
	mkdir -p "$patches_dir" "$integrations_dir" "$cli_dir"

	pr "Getting prebuilts (${patches_src%/*})" >&2
	local rv_cli_url rv_integrations_url rv_patches rv_patches_dl rv_patches_url rv_patches_json

	rv_cli_url=$(gh_req "https://api.github.com/repos/${cli_src}/releases/latest" - | json_get 'browser_download_url') || return 1
	local rv_cli_jar="${cli_dir}/${rv_cli_url##*/}"
	echo "\n**CLI**: $(cut -d/ -f4 <<<"$rv_cli_url")/$(cut -d/ -f9 <<<"$rv_cli_url")" >>"$patches_dir/changelog.md"

	local rv_integrations_rel="https://api.github.com/repos/${integrations_src}/releases/latest"
	local rv_patches_rel="https://api.github.com/repos/${patches_src}/releases/latest"
	
	rv_integrations_url=$(gh_req "$rv_integrations_rel" - | json_get 'browser_download_url' | grep -E '\.apk$')
	local rv_integrations_apk="${integrations_dir}/${rv_integrations_url##*/}"
	echo "**Integrations**: $(cut -d/ -f4 <<<"$rv_integrations_url")/$(cut -d/ -f9 <<<"$rv_integrations_url")" >>"$patches_dir/changelog.md"

	rv_patches=$(gh_req "$rv_patches_rel" -)
	rv_patches_dl=$(json_get 'browser_download_url' <<<"$rv_patches")
	rv_patches_json="${patches_dir}/patches-$(json_get 'tag_name' <<<"$rv_patches").json"
	rv_patches_url=$(grep -E '\.jar$' <<<"$rv_patches_dl")
	local rv_patches_jar="${patches_dir}/${rv_patches_url##*/}"
	[ -f "$rv_patches_jar" ] || REBUILD=true
	echo "**Patches**: $(cut -d/ -f4 <<<"$rv_patches_url")/$(cut -d/ -f9 <<<"$rv_patches_url")" >>"$patches_dir/changelog.md"

	dl_if_dne "$rv_cli_jar" "$rv_cli_url" >&2
	dl_if_dne "$rv_integrations_apk" "$rv_integrations_url" >&2
	dl_if_dne "$rv_patches_jar" "$rv_patches_url" >&2
	dl_if_dne "$rv_patches_json" "$(grep 'json' <<<"$rv_patches_dl")" >&2

	echo "$rv_cli_jar" "$rv_integrations_apk" "$rv_patches_jar" "$rv_patches_json"
}

_req() {
	if [ "$2" = - ]; then
		wget -nv -O "$2" --header="$3" "$1"
	else
		local dlp
		dlp="$(dirname "$2")/tmp.$(basename "$2")"
		if [ -f "$dlp" ]; then
			while [ -f "$dlp" ]; do sleep 1; done
			return
		fi
		wget -nv -O "$dlp" --header="$3" "$1" || return 1
		mv -f "$dlp" "$2"
	fi
}
req() { _req "$1" "$2" "User-Agent: Mozilla/5.0 (X11; Linux x86_64; rv:108.0) Gecko/20100101 Firefox/108.0"; }
gh_req() { _req "$1" "$2" "$GH_HEADER"; }

log() { echo -e "$1  " >>"build.md"; }
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
	local inc_sel exc_sel vs
	inc_sel=$(list_args "$2" | sed 's/.*/\.name == &/' | paste -sd '~' | sed 's/~/ or /g' || :)
	exc_sel=$(list_args "$3" | sed 's/.*/\.name != &/' | paste -sd '~' | sed 's/~/ and /g' || :)
	inc_sel=${inc_sel:-false}
	if [ "$4" = false ]; then inc_sel="${inc_sel} or .use==true"; fi
	if ! vs=$(jq -r ".[]
			| select(.compatiblePackages // [] | .[] | .name==\"${1}\")
			| select(${inc_sel})
			| select(${exc_sel:-true})
			| .compatiblePackages[].versions // []" "$5"); then
		abort "error in jq query"
	fi
	tr -d ' ,\t[]"' <<<"$vs" | sort -u | grep -v '^$' | get_largest_ver || :
}

dl_if_dne() {
	[ "${DRYRUN:-}" ] && {
		: >"$1"
		return 0
	}
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
		: >"$output"
		return 0
	}
	local resp node app_table dlurl=""
	[ "$arch" = universal ] && apparch=(universal noarch 'arm64-v8a + armeabi-v7a') || apparch=("$arch")
	url="${url}/${url##*/}-${version//./-}-release/"
	resp=$(req "$url" -) || return 1
	for ((n = 1; n < 40; n++)); do
		node=$($HTMLQ "div.table-row.headerFont:nth-last-child($n)" -r "span:nth-child(n+3)" <<<"$resp")
		if [ -z "$node" ]; then break; fi
		app_table=$($HTMLQ --text --ignore-whitespace <<<"$node")
		if [ "$(sed -n 3p <<<"$app_table")" = "$apkorbundle" ] && { [ "$apkorbundle" = BUNDLE ] ||
			{ [ "$apkorbundle" = APK ] && [ "$(sed -n 6p <<<"$app_table")" = "$dpi" ] &&
				isoneof "$(sed -n 4p <<<"$app_table")" "${apparch[@]}"; }; }; then
			dlurl=$($HTMLQ --base https://www.apkmirror.com --attribute href "div:nth-child(1) > a:nth-child(1)" <<<"$node")
			break
		fi
	done
	[ -z "$dlurl" ] && return 1
	url=$(req "$dlurl" - | $HTMLQ --base https://www.apkmirror.com --attribute href "a.btn")
	if [ "$apkorbundle" = BUNDLE ] && [[ "$url" != *"&forcebaseapk=true" ]]; then url="${url}&forcebaseapk=true"; fi
	url=$(req "$url" - | $HTMLQ --base https://www.apkmirror.com --attribute href "span > a[rel = nofollow]")
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
	local stock_input=$1 patched_apk=$2 patcher_args=$3 rv_cli_jar=$4 rv_patches_jar=$5 rv_integ_apk=$6
	local cmd="java -jar $rv_cli_jar patch -b $rv_patches_jar -m $rv_integ_apk -o $patched_apk -p --rip-lib x86_64 --rip-lib x86 --rip-lib armeabi-v7a --keystore=revanced.keystore $patcher_args $stock_input"
	pr "$cmd"
	if [ "${DRYRUN:-}" = true ]; then
		cp -f "$stock_input" "$patched_apk"
	else
		eval "$cmd"
	fi
	[ -f "$patched_apk" ]
}

build_rv() {
	eval "declare -A args=${1#*=}"
	local version build_mode_arr pkg_name
	local mode_arg=${args[build_mode]} version_mode=${args[version]}
	local app_name=${args[app_name]}
	local app_name_l=${app_name,,}
	app_name_l=${app_name_l// /-}
	local table=${args[table]}
	local dl_from=${args[dl_from]}
	local arch=${args[arch]}
	if [ "$arch" = 'universal' ]; then local arch_f="all"; else local arch_f="$arch"; fi

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
				"${args[included_patches]}" "${args[excluded_patches]}" "${args[exclusive_patches]}" "${args[ptjs]}"
		) || get_latest_ver=true
	elif isoneof "$version_mode" latest beta; then
		get_latest_ver=true
		p_patcher_args+=("-f")
	else
		version=$version_mode
		p_patcher_args+=("-f")
	fi
	if [ $get_latest_ver = true ]; then
		local apkmvers
		if [ "$dl_from" = apkmirror ]; then
		apkmvers=$(get_apkmirror_vers "${args[apkmirror_dlurl]##*/}" "false")
		version=$(get_largest_ver <<<"$apkmvers") || version=$(head -1 <<<"$apkmvers")
		fi
	fi
	if [ -z "$version" ]; then
		epr "empty version, not building ${table}."
		return 0
	fi
	pr "Choosing version '${version}' for ${table}"
	local version_f=${version// /}
	version_f=${version_f#v}
	local stock_apk="${TEMP_DIR}/${pkg_name}-${version_f}-${arch_f}.apk"
	if [ ! -f "$stock_apk" ]; then
		if [ -z "${args[apkmirror_dlurl]}" ]; then continue; fi
		pr "Downloading '${table}' from APKMirror"
		local apkm_arch
		if [ "$arch" = "universal" ]; then
			apkm_arch="universal"
		elif [ "$arch" = "arm64-v8a" ]; then
			apkm_arch="arm64-v8a"
		elif [ "$arch" = "arm-v7a" ]; then
			apkm_arch="armeabi-v7a"
		fi
		if ! dl_apkmirror "${args[apkmirror_dlurl]}" "$version" "$stock_apk" APK "$apkm_arch" "${args[dpi]}"; then
			epr "ERROR: Could not find any release of '${table}' with version '${version}', arch '${apkm_arch}' and dpi '${args[dpi]}' from APKMirror"
			continue
		fi
		if [ ! -f "$stock_apk" ]; then return 0; fi
	fi
	log "${table}: ${version}"

	local microg_patch
	microg_patch=$(jq -r ".[] | select(.compatiblePackages // [] | .[] | .name==\"${pkg_name}\") | .name" "${args[ptjs]}" | grep -iF microg || :)
	if [ "$microg_patch" ]; then
		p_patcher_args=("${p_patcher_args[@]//-[ei] ${microg_patch}/}")
	fi

	local stock_bundle_apk="${TEMP_DIR}/${pkg_name}-${version_f}-${arch_f}-bundle.apk"
	local is_bundle=false
	build_mode_arr=(apk)
	local patcher_args patched_apk build_mode
	local rv_brand_f=${args[rv_brand],,}
	rv_brand_f=${rv_brand_f// /-}
	for build_mode in "${build_mode_arr[@]}"; do
		patcher_args=("${p_patcher_args[@]}")
		pr "Building '${table}' in '$build_mode' mode"
		if [ "$microg_patch" ]; then
			patched_apk="${TEMP_DIR}/${app_name_l}-${rv_brand_f}-${version_f}-${arch_f}-${build_mode}.apk"
			patcher_args+=("-i \"${microg_patch}\"")
		else
			patched_apk="${TEMP_DIR}/${app_name_l}-${rv_brand_f}-${version_f}-${arch_f}.apk"
		fi
		if [ ! -f "$patched_apk" ] || [ "$REBUILD" = true ]; then
			if ! patch_apk "$stock_apk" "$patched_apk" "${patcher_args[*]}" "${args[cli]}" "${args[ptjar]}" "${args[integ]}"; then
				epr "Building '${table}' failed!"
				return 0
			fi
		fi
		if [ "$build_mode" = apk ]; then
			local apk_output="${BUILD_DIR}/${app_name_l}-${rv_brand_f}-v${version_f}-${arch_f}.apk"
			cp -f "$patched_apk" "$apk_output"
			pr "Built ${table} (non-root): '${apk_output}'"
			continue
		fi
	done
}

list_args() { tr -d '\t\r' <<<"$1" | tr -s ' ' | sed 's/" "/"\n"/g' | sed 's/\([^"]\)"\([^"]\)/\1'\''\2/g' | grep -v '^$' || :; }
join_args() { list_args "$1" | sed "s/^/${2} /" | paste -sd " " - || :; }
