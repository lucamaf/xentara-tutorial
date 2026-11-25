#!/bin/bash

# Installer for Xentara on RPM-based distributions (RHEL, CentOS Stream, Rocky, AlmaLinux, Oracle Linux, Fedora).
#
# Xentara is only published as Debian packages in an APT repository. This script therefore:
#   1. downloads and cryptographically verifies the APT repository metadata (InRelease -> Packages -> .deb SHA256),
#   2. downloads the selected .deb packages (and the Xentara packages they depend on),
#   3. converts them to RPM packages using 'alien', which runs in a Debian 12 container (podman or docker),
#   4. installs the RPMs with DNF, together with the mapped system library dependencies.
#
# This is the counterpart of xentara-installer.sh, which handles Debian/Ubuntu using APT.

# fail on first error
set -e
# fail on first error in a pipeline
set -o pipefail

# use some shell options
shopt -s extglob
shopt -s globasciiranges
shopt -s checkwinsize

#########################################
# Parse the command line options
#########################################

# show the usage
show_usage() {
	local script_name=${0##*/}
	echo -e "Usage: ${script_name} [OPTIONS]
Interactive installer for Xentara and related packages (RPM-based distributions)

  --preview             Install the developer preview of Xentara. This option requires a Xentara
                        developer account
  --testing             Include unsupported test versions of Xentara skills.
                        \e[31mWARNING: Software installed using this option is intended to be used for
                        testing and evaluation purposes only. There is no warranty, express or implied,
                        to the extent permissible by law for Software installed using this options. Test
                        versions of Xentara or Xentara skills must not be used in productive systems.\e[0m
  --customer=CUSTOMER   Show customer-specific packages for customer 'CUSTOMER'.
  --version=MAJOR.MINOR Install a specific version of Xentara (2.0 or later).
  --internal            For use by embedded ocean GmbH only. Do not use this option.
  --debug               For use by embedded ocean GmbH only. Do not use this option.
  --licence-server      Install the Xentara floating licence server instead of installing Xentara
  -h, --help            Show this message and exit.

You can only specify at most one of '--preview', '--testing', and '--debug'

Xentara is not published as RPM packages. This installer converts the official Debian packages (built for
Debian 12 \"bookworm\") to RPM packages on this machine."
}

# handle a usage error
usage_error() {
	# get the message string
	local message="$1"
	if [[ ! -z ${message} ]] ; then
		echo "ERROR: ${message}
" > /dev/stderr
	fi

	# show the usage
	show_usage > /dev/stderr

	exit 1
}

# Parse the command line arguments
declare -a selected_repo
customer=
version=
install_type=XENTARA
while (( $# > 0 )) ; do
	case "$1" in
		--preview )
			selected_repo+=("PREVIEW")
			;;

		--testing )
			selected_repo+=("TESTING")
			;;

		--internal )
			selected_repo+=("INTERNAL")
			;;

		--debug )
			selected_repo+=("DEBUG")
			;;

		--customer=* )
			if [[ ! -z ${customer} ]] ; then
				usage_error "'--customer' cannot be specified multiple times"
			fi

			customer="${1:11}"
			customer="${customer,,}"
			;;

		--version=* )
			if [[ ! -z ${version} ]] ; then
				usage_error "'--version' cannot be specified multiple times"
			fi

			version="${1:10}"

			if [[ ! ${version} =~ ^[1-9][0-9]*\.(0|[1-9][0-9]*)$ ]] ; then
				usage_error "'${version}' is not a valid version number. The version number must have the form 'MAJOR.MINOR', for example '2.0' or '2.1'"
			fi

			# the Debian 12 "bookworm" packages we convert only exist for Xentara 2.0 and later
			if (( ${version%%.*} < 2 )) ; then
				usage_error "This installer only supports Xentara 2.0 and later"
			fi
			;;

		--licence-server )
			install_type=LICENCE_SERVER
			;;

		--help|-h )
			show_usage
			exit 0
			;;

		-- )
			if (( $# > 1 )) ; then
				usage_error "Extra arguments after '--'"
			fi

			break
			;;

		*)
			usage_error "Unknown option '$1'"
			exit 0
	esac

	shift
done

# can only specify a single repo
if (( ${#selected_repo[@]} > 1 )) ; then
	usage_error "Please specify at most one of '--preview', '--testing', '--internal', and '--debug'"
fi

# cannot specify a version with --preview
if [[ ${selected_repo} == PREVIEW && ! -z ${version} ]] ; then
	usage_error "'--preview' cannot be used together with '--version'"
fi

#########################################
# Set up the repository properties
#########################################

# The Debian suite whose packages are converted. Debian 12 "bookworm" has the lowest system library requirements
# (glibc 2.36, GCC 12.2), so it is the most likely to run on RPM-based distributions.
suite_prefix="debian-bookworm/"

# Set up to use the release repo
use_release_repo() {
	# set the URLs
	main_repo_url=https://download.xentara.io/apt/
	customer_url_base=https://download.xentara.io/customers/

	# set the suites
	if [[ -z ${version} ]] ; then
		repo_suites=(${suite_prefix}stable)
	else
		repo_suites=(${suite_prefix}${version})
	fi

	# set other options
	repo_components=(non-free misc)
	need_developer_credentials=false
}

# Set up to use the preview repo
use_preview_repo() {
	# set the URLs
	main_repo_url=https://developer.xentara.io/apt/
	customer_url_base=https://developer.xentara.io/customers/

	# always use the prerelease suite
	repo_suites=(${suite_prefix}prerelease)

	# set other options
	repo_components=(non-free misc)
	need_developer_credentials=true
}

# Set up to use the testing repo
use_testing_repo() {
	# set the URLs
	main_repo_url=https://download.xentara.io/apt/
	customer_url_base=https://download.xentara.io/customers/

	# set the suites
	if [[ -z ${version} ]] ; then
		repo_suites=(${suite_prefix}stable ${suite_prefix}testing)
	else
		repo_suites=(${suite_prefix}${version} ${suite_prefix}${version}-testing)
	fi

	# set other options
	repo_components=(non-free misc)
	need_developer_credentials=false
}

# Set up to use the internal repo
use_internal_repo() {
	# set the URLs
	main_repo_url=http://eog-build.xentara.internal/repos/apt/
	customer_url_base=

	# set the suites
	if [[ -z ${version} ]] ; then
		repo_suites=(${suite_prefix}prerelease)
	else
		repo_suites=(${suite_prefix}${version} ${suite_prefix}${version}-testing)
	fi

	# set other options
	repo_components=(non-free misc)
	need_developer_credentials=false
}

# Set up to use the debug repo
use_debug_repo() {
	main_repo_url=http://eog-build.xentara.internal/repos/apt/
	customer_url_base=

	# set the suites
	if [[ -z ${version} ]] ; then
		repo_suites=(${suite_prefix}prerelease ${suite_prefix}prerelease-debug)
	else
		repo_suites=(${suite_prefix}${version} ${suite_prefix}${version}-debug ${suite_prefix}${version}-testing ${suite_prefix}${version}-debug-testing)
	fi

	# set other options
	repo_components=(non-free misc)
	need_developer_credentials=false
}

# make customer suites
add_customer_suites() {
	# get a reference to the output
	local -n suites="$1"
	# get the customer
	local customer="$2"

	# go through all the existing suites
	local -a customer_suites
	for suite in "${suites[@]}" ; do
		customer_suites+=("${suite}/${customer}")
	done

	# add them
	suites+=("${customer_suites[@]}")
}

setup_repo() {
	# Select the correct repo
	case "${selected_repo}" in
			PREVIEW )
				use_preview_repo
				;;
			TESTING )
				use_testing_repo
				;;
			INTERNAL )
				use_internal_repo
				;;
			DEBUG )
				use_debug_repo
				;;
			*)
				use_release_repo
	esac

	# handle the customer
	if [[ -z ${customer} ]] ; then
		customer_repo_url=
		need_customer_credentials=false
	else
		# see if we have a separate URL
		if [[ -z ${customer_url_base} ]] ; then
			customer_repo_url=
			add_customer_suites repo_suites "${customer}"
			need_customer_credentials=false
		else
			customer_repo_url="${customer_url_base}${customer}/apt/"
			need_customer_credentials=true
		fi
	fi

	# make the list of repositories
	repo_urls=("${main_repo_url}")
	if [[ ! -z ${customer_repo_url} ]] ; then
		repo_urls+=("${customer_repo_url}")
	fi
}

#########################################
# Define some useful helper functions
#########################################

# get the base URL
get_base_url() {
	[[ "$1" =~ ^[-a-zA-Z0-9+.]+:\/\/[^/?#]+ ]] && echo "${BASH_REMATCH}"
}

# function to encode a string using URL encoding
url_encode() {
	# we are going to modify LC_ALL, so resore the original value on exit
    trap "LC_ALL=${LC_ALL} ; trap - RETURN" RETURN

	# do everything in the C locale:
	# - UTF-8 characters need to be interpreted as individual bytes
	# - character ranges in case need to be interpreted as ASCII code ranges
	LC_ALL=C

	# get the parameter
	local input="${1}"
	# get the length of the string
	local input_length=${#input}

	# start with an empty output
	local output=''

	# loop thgrough all the characters and convert them
	local i character encoded_character
	for (( i=0 ; i<input_length ; i++ )); do
		# get a character. LC_CTYPE=C disables character parsing and
		character=${input:$i:1}
		# convert íllegal characters
		case "${character}" in
			# these characters can be used as-is in URIs
			[a-zA-Z0-9.~_-] )
				encoded_character="${character}"
				;;

			# the rest needs to be URL-encoded
			* )
				printf -v encoded_character '%%%02x' "'${character}"
				;;
		esac

		# add the encoded character to the output
		output+="${encoded_character}"
	done

	# output the result
	echo "${output}"
}

# Remembers the credentials for a repository URL. They are embedded in the download URLs (which are passed
# to wget through stdin, so that they do not show up in the process list).
declare -A repo_user_names
declare -A repo_passwords
store_credentials() {
	local user_name="$1"
	local password="$2"
	local url="$3"

	repo_user_names["${url}"]="${user_name}"
	repo_passwords["${url}"]="${password}"
}

# adds the stored credentials to a URL, if it belongs to a repository that needs them
add_credentials() {
	local url="$1"

	local repo_url
	for repo_url in "${!repo_user_names[@]}" ; do
		if [[ ${url} == "${repo_url}"* && ${url} =~ ^([-a-zA-Z0-9+.]+://)(.*)$ ]] ; then
			echo "${BASH_REMATCH[1]}$(url_encode "${repo_user_names[${repo_url}]}"):$(url_encode "${repo_passwords[${repo_url}]}")@${BASH_REMATCH[2]}"
			return
		fi
	done

	echo "${url}"
}

# Downloads a file to the destination path. Returns non-zero on failure, but only shows the log if $3 is not "quiet".
download_file() {
	# get the URL
	local url="$1"
	# get the destination
	local destination="$2"
	# get the verbosity
	local mode="$3"

	# create a temporary log file for wget. We use a log file, because we only want to show the output on error.
	local log_file_path=$(mktemp -p "${work_dir}")

	# download the file
	if add_credentials "${url}" | wget --output-file="${log_file_path}" --no-verbose --input-file=- --no-netrc --output-document="${destination}" ; then
		rm -f "${log_file_path}"
	else
		if [[ ${mode} != quiet ]] ; then
			{ echo -en '\e[31m' ; cat "${log_file_path}"; echo -en '\e[96m'; } > /dev/stderr
		fi
		rm -f "${log_file_path}" "${destination}"
		return 1
	fi
}

# Checks a URL using wget. Does not output anything, but returns the result of wget.
check_credentials() {
	# get the user name and password, converting them to URL encoding at the same time
	local user_name=$(url_encode "$1")
	local password=$(url_encode "$2")

	# get the URL
	local url="$3"

	# Without a user name it will not work
	if [[ -z ${user_name} ]]; then
	   return 1
	fi

	# Create a URL with the user name and password in it. This will only work for HTTPs, but using basic authentication
	# in unecrypted connections is a bad idea anyways
	[[ ${url} =~ ^([-a-zA-Z0-9+.]+://)(.*)$ ]] && url="${BASH_REMATCH[1]}${user_name}:${password}@${BASH_REMATCH[2]}"

	# call wget. The "&& :" prevents set -e from terminating the script on error
	echo "${url}" | wget --quiet --method=HEAD --input-file=- --no-netrc && :

	# wget return 6 on authentication error
	[[ $? != 6 ]]
}

# Get credentials
get_credentials() {
	# get the URL
	local url="$1"
	# get a reference to the output variables
	local -n local_user_name="$2"
	local -n local_password="$3"

	# get the predefined user name
	local fixed_user_name="$4"

	# get the base URL for output
	local base_url=$(get_base_url "${url}")

	# loop until the user name and password is valid
	while true ; do
		# get the user name if none was given
		if [[ -z ${fixed_user_name} ]] ; then
			# get the user name
			echo -en "[\e[93m${base_url}\e[96m] user name: "
			# (The IFS='' tells read to honour spaces at the beginning and end of the input)
			IFS='' read -e local_user_name

			# Without a user name, nothing will be echoed and there will be no line feed
			if [[ -z ${local_user_name} ]]; then
				echo
			fi
		# use the fixed user name, if one was given
		else
			local_user_name="${fixed_user_name}"
		fi

		# get the password
		echo -en "[\e[93m${base_url}\e[96m] password: "
		IFS='' read -es local_password

		# check the authentication
		if check_credentials "${local_user_name}" "${local_password}" "${url}" ; then
			break
		else
			echo 'Invalid user name or password'
		fi
	done
}

# removes an item from an array
filter_array() {
	# get a reference to the array to filter
	local -n array="$1"
	# get the filter element
	local filter_element="$2"

	# collect all element
	local -a filtered_array
	for element in "${array[@]}" ; do
		if [[ ${element} != ${filter_element} ]] ; then
			filtered_array+=("${element}")
		fi
	done

	# set them
	array=("${filtered_array[@]}")
}

#########################################
# Helper functions for checking packages
#########################################

# check whether a package is installed. Also checks the +debug version.
is_package_installed() {
	local package="$1"

	rpm --quiet --query "${package}" || rpm --quiet --query "${package}+debug"
}

# returns success if version $1 is greater than or equal to version $2
version_ge() {
	[[ -n $1 && "$(printf '%s\n%s\n' "$2" "$1" | LC_ALL=C sort -V | head -n 1)" == "$2" ]]
}

# check that a system package version is available
check_package_version() {
	# get the package
	local package="$1"
	# get the desired version
	local desired_version="$2"

	# Use the installed version if there is one (this is what the binaries will run against). Otherwise ask DNF,
	# using the cache only (-C), so that this never blocks on a metadata download or a hidden prompt.
	local available_version=$(rpm --query --qf '%{version}\n' "${package}" 2> /dev/null | tail -n 1)
	if [[ -z ${available_version} ]] ; then
		available_version=$(LANG=C dnf -C --quiet repoquery --latest-limit=1 --arch="$(uname -m)" --qf '%{version}\n' "${package}" 2> /dev/null < /dev/null | tail -n 1)
	fi

	# compare the versions
	version_ge "${available_version}" "${desired_version}" && :
}

#########################################
# Debian package index
#########################################

# Information about all the packages in the repositories, indexed by package name
declare -A pkg_versions
declare -A pkg_descriptions
declare -A pkg_depends
declare -A pkg_urls
declare -A pkg_sha256s
# virtual package names (Provides:) and the package that provides them
declare -A provided_by

# registers a package from a Packages file stanza, keeping the highest version if it occurs several times
register_package() {
	local package="$1"
	local package_version="$2"
	local description="$3"
	local depends="$4"
	local url="$5"
	local sha256="$6"
	local provides="$7"

	# ignore incomplete stanzas
	if [[ -z ${package} || -z ${package_version} || -z ${url} || -z ${sha256} ]] ; then
		return
	fi

	# keep the highest version
	local existing_version="${pkg_versions[${package}]}"
	if [[ -n ${existing_version} && ${existing_version} != "${package_version}" ]] && ! version_ge "${package_version}" "${existing_version}" ; then
		return
	fi

	pkg_versions[${package}]="${package_version}"
	pkg_descriptions[${package}]="${description}"
	pkg_depends[${package}]="${depends}"
	pkg_urls[${package}]="${url}"
	pkg_sha256s[${package}]="${sha256}"

	local virtual_package
	while read -r virtual_package ; do
		if [[ -n ${virtual_package} && ${virtual_package} != "${package}" ]] ; then
			provided_by[${virtual_package}]="${package}"
		fi
	done < <(parse_deb_depends "${provides}")
}

# gets the SHA256 hash of a file listed in a Release file
get_release_hash() {
	local release_file="$1"
	local path="$2"

	awk -v path="${path}" '/^SHA256:/ { in_block = 1; next } /^[^ ]/ { in_block = 0 } in_block && $3 == path { print $1; exit }' "${release_file}"
}

# Downloads, verifies and reads the package list from one repo / suite / component.
declare -i index_counter=0
collect_packages() {
	local repo="$1"
	local suite="$2"
	local component="$3"

	local suite_dir="${work_dir}/index/${suite//\//_}_${repo//[^a-zA-Z0-9]/_}"
	local release_file="${suite_dir}/Release"
	local dists_url="${repo}dists/${suite}"

	# download and verify the Release file once per repo / suite
	if [[ ! -f ${release_file} ]] ; then
		mkdir -p "${suite_dir}"

		if download_file "${dists_url}/InRelease" "${suite_dir}/InRelease" quiet ; then
			gpgv --quiet --keyring "${keyring_path}" --output "${release_file}" "${suite_dir}/InRelease" 2> /dev/null || release_file_invalid=true
		elif download_file "${dists_url}/Release" "${release_file}" quiet && download_file "${dists_url}/Release.gpg" "${suite_dir}/Release.gpg" quiet ; then
			gpgv --quiet --keyring "${keyring_path}" "${suite_dir}/Release.gpg" "${release_file}" 2> /dev/null || release_file_invalid=true
		else
			# no such suite in this repo
			return 0
		fi

		if [[ ${release_file_invalid} == true ]] ; then
			echo -e "\e[31mERROR: The signature of ${dists_url}/ could not be verified. Aborting.\e[96m" > /dev/stderr
			exit 1
		fi
	fi

	# find the package list
	local list_path
	local list_hash
	local list_extension
	for list_extension in xz gz '' ; do
		list_path="${component}/binary-${deb_arch}/Packages${list_extension:+.}${list_extension}"
		list_hash=$(get_release_hash "${release_file}" "${list_path}")
		if [[ -n ${list_hash} ]] ; then
			break
		fi
	done
	if [[ -z ${list_hash} ]] ; then
		return 0
	fi

	# download it and check the hash
	local list_file="${suite_dir}/Packages_${component}.${list_extension:-plain}"
	download_file "${dists_url}/${list_path}" "${list_file}" || exit 1
	if [[ $(sha256sum "${list_file}" | cut -d ' ' -f 1) != "${list_hash}" ]] ; then
		echo -e "\e[31mERROR: The package list ${dists_url}/${list_path} does not match its signed checksum. Aborting.\e[96m" > /dev/stderr
		exit 1
	fi

	# read the package list
	local package="" package_version="" description="" depends="" filename="" sha256="" provides=""
	local line
	while IFS= read -r line ; do
		# an empty line separates the stanzas
		if [[ -z ${line} ]] ; then
			register_package "${package}" "${package_version}" "${description}" "${depends}" "${filename:+${repo}${filename}}" "${sha256}" "${provides}"
			package="" package_version="" description="" depends="" filename="" sha256="" provides=""
		fi

		# interpret the line
		case "${line}" in
			Package:* )
				package="${line/#Package:+( )/}"
				;;
			Version:* )
				package_version="${line/#Version:+( )/}"
				;;
			Description:* )
				description="${line/#Description:+( )/}"
				;;
			Depends:* )
				depends+="${depends:+, }${line/#Depends:+( )/}"
				;;
			Pre-Depends:* )
				depends+="${depends:+, }${line/#Pre-Depends:+( )/}"
				;;
			Provides:* )
				provides="${line/#Provides:+( )/}"
				;;
			Filename:* )
				filename="${line/#Filename:+( )/}"
				;;
			SHA256:* )
				sha256="${line/#SHA256:+( )/}"
				;;
			* )
		esac
	done < <(
		case "${list_extension}" in
			xz ) xz --decompress --stdout "${list_file}" ;;
			gz ) gzip --decompress --stdout "${list_file}" ;;
			* ) cat "${list_file}" ;;
		esac
	)

	# add any package that was left over from the last block in the file
	register_package "${package}" "${package_version}" "${description}" "${depends}" "${filename:+${repo}${filename}}" "${sha256}" "${provides}"
}

#########################################
# Helper functions for collecting the skills
#########################################

# function to declare a skill
declare -a installed_skill_packages
declare -a available_skill_packages
declare -A skill_descriptions
max_skill_package_name_length=0

# returns success if the package is a skill (i.e. not Xentara itself, the licence server, a developer or debug package, or the signing key)
is_skill_package() {
	local package="$1"

	! [[ ${package} == xentara || \
	     ${package} =~ ^xentara(-[a-z0-9]+)*-dev$ || \
	     ${package} =~ ^xentara(-[a-z0-9]+)*-dev- || \
	     ${package} == xentara-licence-server || \
	     ${package} == xentara-archive-keyring || \
	     ${package} =~ \+debug$ ]]
}

# function to add a skill
add_skill() {
	# get the name and package name
	local package="$1"
	local description="$2"

	# don't add any empty skills
	if [[ -z ${package} || -z ${description} ]] ; then
		return
	fi

	# don't add Xentara itself, the licence server, any developer packages, any debug packages, or the signing key
	if [[ ${package} == xentara || \
	      ${package} =~ ^xentara(-[a-z0-9]+)*-dev$ || \
		  ${package} =~ ^xentara(-[a-z0-9]+)*-dev- || \
		  ${package} == xentara-licence-server || \
		  ${package} == xentara-archive-keyring || \
		  ${package} =~ \+debug$ ]] ; then
		return
	fi

	# define the properties
	skill_descriptions[${package}]="${description}"

	# update the package name length
	local package_name_length=${#package}
	if (( ${package_name_length} > ${max_skill_package_name_length} )) ; then
		max_skill_package_name_length=${package_name_length}
	fi

	# add the skill to the correct list
	if is_package_installed "${package}" ; then
		installed_skill_packages+=("${package}")
	else
		available_skill_packages+=("${package}")
	fi
}

# function to turn the package list into the skill lists
declare -a skill_selections
declare -A skill_packages
declare -a unsupported_skills
collect_skills() {
	local package unsupported_dependency
	for package in "${!pkg_versions[@]}" ; do
		# leave out skills that cannot work on RPM-based distributions
		if unsupported_dependency=$(get_unsupported_dependency "${package}") ; then
			if is_skill_package "${package}" ; then
				unsupported_skills+=("${package} (needs Debian ${unsupported_dependency})")
			fi
			continue
		fi
		add_skill "${package}" "${pkg_descriptions[${package}]}"
	done
}

# function to turn the list of skills collected by collect_skills into the installed skill list
print_installed_skills() {
	# sort the skills
	IFS=$'\n' installed_skill_packages=($(sort -u <<< "${installed_skill_packages[*]}"))

	# make a list of skill selections
	for package in "${installed_skill_packages[@]}" ; do
		printf -- "%-${max_skill_package_name_length}s   ${skill_descriptions[${package}]}\n" "${package}"
	done
}

# function to turn the list of skills collected by collect_skills into the selection list
make_skill_selection() {
	# sort the skills
	IFS=$'\n' available_skill_packages=($(sort -u <<< "${available_skill_packages[*]}"))

	# make a list of skill selections
	for package in "${available_skill_packages[@]}" ; do
		local skill_selection=$(printf "%-${max_skill_package_name_length}s   ${skill_descriptions[${package}]}\n" "${package}")
		skill_selections+=("${skill_selection}")
		skill_packages[${skill_selection}]="${package}"
	done
}

#########################################
# Dependency mapping and package conversion
#########################################

# Maps Debian system library packages to RPM packages. Debian dependencies that are neither Xentara packages
# nor listed here are dropped (with a warning). Extend this table as needed.
declare -A deb_to_rpm_map=(
	['libc6']='glibc'
	['libstdc++6']='libstdc++'
	['libgcc-s1']='libgcc'
	['libatomic1']='libatomic'
	['libssl3']='openssl-libs'
	['zlib1g']='zlib'
	['libzstd1']='libzstd'
	['liblzma5']='xz-libs'
	['libbz2-1.0']='bzip2-libs'
	['libcap2']='libcap'
	['libsystemd0']='systemd-libs'
	['libudev1']='systemd-libs'
	['libyaml-0-2']='libyaml'
	['libpcre2-8-0']='pcre2'
	['ca-certificates']='ca-certificates'
	['systemd']='systemd'
)

# Debian libraries that cannot be used on RPM-based distributions, because the Xentara binaries were linked against
# Debian-specific symbol versions that the RHEL/Fedora builds of these libraries do not have (e.g. CURL_OPENSSL_4).
# Packages that depend on one of these cannot be installed, and are not offered as skills.
declare -a unsupported_deb_depends=(libcurl4 libcurl3 libcurl3-gnutls)

# Prints the first unsupported Debian library that a package depends on directly, if any
get_unsupported_dependency() {
	local package="$1"
	local dependency unsupported
	while read -r dependency ; do
		for unsupported in "${unsupported_deb_depends[@]}" ; do
			if [[ ${dependency} == "${unsupported}" ]] ; then
				echo "${dependency}"
				return 0
			fi
		done
	done < <(parse_deb_depends "${pkg_depends[${package}]}")
	return 1
}

# Splits a Debian dependency field into plain package names. Only the first alternative of "a | b" is used,
# and version constraints and architecture qualifiers are removed.
parse_deb_depends() {
	local depends="$1"

	local -a items
	IFS=',' read -ra items <<< "${depends}"

	local item
	for item in "${items[@]}" ; do
		# first alternative only
		item="${item%%|*}"
		# remove version constraints
		item="${item%%(*}"
		# remove architecture qualifiers
		item="${item%%:*}"
		# trim whitespace
		item="${item//[[:space:]]/}"
		if [[ -n ${item} ]] ; then
			echo "${item}"
		fi
	done
}

# Resolves the dependencies of the given packages. Sets:
#   resolved_packages  - the Xentara packages that need to be converted and installed (dependencies first not required,
#                        since everything is installed in one DNF transaction)
#   system_packages    - the RPM system packages that need to be installed
#   dropped_depends    - Debian dependencies that could not be mapped
declare -a resolved_packages
declare -a system_packages
declare -a dropped_depends
declare -A resolve_seen
resolve_packages() {
	resolved_packages=()
	system_packages=()
	dropped_depends=()
	resolve_seen=()

	local -a queue=("$@")
	local package dependency rpm_package
	while (( ${#queue[@]} )) ; do
		package="${queue[0]}"
		queue=("${queue[@]:1}")

		if [[ -n ${resolve_seen[${package}]} ]] ; then
			continue
		fi
		resolve_seen[${package}]=1

		# packages that are already installed do not need to be handled again
		if is_package_installed "${package}" ; then
			continue
		fi

		if [[ -z ${pkg_versions[${package}]} ]] ; then
			echo -e "\e[31mERROR: The package '${package}' was not found in the Xentara repositories.\e[96m" > /dev/stderr
			return 1
		fi

		# refuse packages that cannot work on this system
		if dependency=$(get_unsupported_dependency "${package}") ; then
			echo -e "\e[31mERROR: '${package}' cannot be installed on RPM-based distributions, because it needs the Debian library '${dependency}',
whose symbols are not compatible with the system library.\e[96m" > /dev/stderr
			return 1
		fi

		resolved_packages+=("${package}")

		while read -r dependency ; do
			if [[ -z ${dependency} ]] ; then
				continue
			elif [[ -n ${pkg_versions[${dependency}]} ]] ; then
				queue+=("${dependency}")
			elif [[ -n ${provided_by[${dependency}]} ]] ; then
				# a virtual package: install the package that provides it (if that is not the package itself)
				queue+=("${provided_by[${dependency}]}")
			elif [[ -n ${deb_to_rpm_map[${dependency}]} ]] ; then
				rpm_package="${deb_to_rpm_map[${dependency}]}"
				# newer distributions call the zlib package zlib-ng-compat
				if [[ ${rpm_package} == zlib ]] && ! dnf -C --quiet repoquery zlib 2> /dev/null < /dev/null | grep -q . ; then
					rpm_package=zlib-ng-compat
				fi
				system_packages+=("${rpm_package}")
			else
				dropped_depends+=("${dependency} (required by ${package})")
			fi
		done < <(parse_deb_depends "${pkg_depends[${package}]}")
	done

	# remove duplicates
	if (( ${#system_packages[@]} )) ; then
		system_packages=($(printf '%s\n' "${system_packages[@]}" | sort -u))
	fi
}

# Name of the container image used for the conversion, and the Debian image it is based on. The Debian version is
# the same as the suite the packages come from.
conversion_image=localhost/xentara-deb2rpm:bookworm
conversion_base_image=docker.io/library/debian:bookworm

# The script that runs inside the container. It converts the .deb in every subdirectory of /work to an RPM.
# Debian maintainer scripts frequently use Debian-specific helpers that do not exist on RPM systems, so they are
# only carried over if they do not use any of them.
write_conversion_script() {
	cat > "${convert_dir}/convert.sh" <<'CONVERT_SCRIPT'
#!/bin/bash
for dir in /work/*/ ; do
	pkg_dir="${dir%/}"
	# skip packages that have already been converted by an earlier run
	if ls "${pkg_dir}"/*.rpm > /dev/null 2>&1 ; then
		continue
	fi
	deb_file=$(ls "${pkg_dir}"/*.deb 2> /dev/null | head -n 1)
	if [[ -z ${deb_file} ]] ; then
		continue
	fi

	options=(--to-rpm --keep-version)
	rm -rf "${pkg_dir}/control"
	if dpkg-deb --control "${deb_file}" "${pkg_dir}/control" 2> /dev/null ; then
		scripts_ok=true
		for script in preinst postinst prerm postrm ; do
			if [[ -f ${pkg_dir}/control/${script} ]] && grep -Eq 'deb-systemd|invoke-rc\.d|update-rc\.d|dpkg-maintscript-helper|dpkg-divert|dpkg-statoverride|debconf|db_[a-z]+|adduser|addgroup' "${pkg_dir}/control/${script}" ; then
				scripts_ok=false
			fi
		done
		if ${scripts_ok} ; then
			options+=(--scripts)
		else
			touch "${pkg_dir}/scripts_dropped"
		fi
	fi

	( cd "${pkg_dir}" && fakeroot alien "${options[@]}" "${deb_file}" > alien.log 2>&1 ) || touch "${pkg_dir}/failed"
done
CONVERT_SCRIPT
}

# Returns the container engine to use (podman or docker)
find_container_engine() {
	local engine
	for engine in podman docker ; do
		if command -v "${engine}" > /dev/null ; then
			echo "${engine}"
			return 0
		fi
	done
	return 1
}

# Builds the conversion image, if it does not exist yet
ensure_conversion_image() {
	if "${container_engine}" image inspect "${conversion_image}" > /dev/null 2>&1 ; then
		return 0
	fi

	echo "Building the conversion container image (${conversion_base_image} with alien)..."
	mkdir -p "${work_dir}/image"
	cat > "${work_dir}/image/Containerfile" <<CONTAINERFILE
FROM ${conversion_base_image}
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install --yes --no-install-recommends alien fakeroot rpm dpkg-dev && rm -rf /var/lib/apt/lists/*
CONTAINERFILE
	"${container_engine}" build --tag "${conversion_image}" "${work_dir}/image"
}

# Downloads and verifies a package, and prepares it for conversion
fetch_package() {
	local package="$1"

	local package_dir="${convert_dir}/${package}"
	mkdir -p "${package_dir}"
	local deb_file="${package_dir}/${package}.deb"

	echo "Downloading ${package} ${pkg_versions[${package}]}..."
	download_file "${pkg_urls[${package}]}" "${deb_file}" || return 1

	# verify the checksum against the signed package list
	if [[ $(sha256sum "${deb_file}" | cut -d ' ' -f 1) != "${pkg_sha256s[${package}]}" ]] ; then
		echo -e "\e[31mERROR: The downloaded package '${package}' does not match the checksum in the signed package list.\e[96m" > /dev/stderr
		return 1
	fi
}

# Converts all the downloaded packages in a Debian container
run_conversion() {
	ensure_conversion_image || return 1
	write_conversion_script

	echo "Converting packages to RPM in a container..."
	# (:Z relabels the directory for SELinux)
	"${container_engine}" run --rm --volume "${convert_dir}:/work:Z" "${conversion_image}" bash /work/convert.sh || return 1

	# a rootful container engine (docker) creates root-owned files
	if [[ ${container_engine} == docker ]] ; then
		sudo chown -R "$(id -u):$(id -g)" "${convert_dir}"
	fi
}

# Debian installs libraries in a multiarch directory (e.g. /usr/lib/x86_64-linux-gnu), which is not in the
# library search path of RPM-based distributions. Add it, so that the Xentara libraries can be found.
setup_library_path() {
	local multiarch_dir
	case "$(uname -m)" in
		x86_64 ) multiarch_dir=/usr/lib/x86_64-linux-gnu ;;
		aarch64 ) multiarch_dir=/usr/lib/aarch64-linux-gnu ;;
		armv7l ) multiarch_dir=/usr/lib/arm-linux-gnueabihf ;;
	esac

	if [[ -d ${multiarch_dir} ]] && ! grep -qsx "${multiarch_dir}" /etc/ld.so.conf.d/xentara.conf ; then
		echo "${multiarch_dir}" | sudo cp --no-preserve=mode --remove-destination --no-target-directory /dev/stdin /etc/ld.so.conf.d/xentara.conf
		sudo chmod 0644 /etc/ld.so.conf.d/xentara.conf
	fi
	sudo ldconfig
}

# Does what the Debian maintainer scripts of the Xentara packages would have done, but which is not carried over
# to the converted RPMs:
# - the xentara@.service unit has SupplementaryGroups=realtime, so systemd refuses to start it (status 216/GROUP)
#   unless the 'realtime' group exists
# - the group is also used by the udev rule for /dev/cpu_dma_latency and by /etc/security/limits.d
post_install_setup() {
	setup_library_path

	if ! getent group realtime > /dev/null ; then
		echo "Creating the 'realtime' group..."
		sudo groupadd --system realtime
	fi

	# apply the udev rule for /dev/cpu_dma_latency and pick up the new systemd unit
	sudo udevadm control --reload 2> /dev/null || :
	sudo udevadm trigger --name-match=cpu_dma_latency 2> /dev/null || :
	sudo systemctl daemon-reload || :
}

# Checks that everything the converted RPMs require is available, before dnf is started. The RPMs get their
# requirements from the libraries the binaries are linked against, and some Debian-era libraries (e.g. onnxruntime)
# do not exist in RHEL repositories. Prints the missing ones and returns non-zero if there are any.
check_unresolved_requirements() {
	local -A batch_provides=()
	local -A required_by=()
	local rpm_file line requirement

	# everything the converted packages provide themselves
	for rpm_file in "$@" ; do
		while read -r line ; do
			batch_provides["${line%% *}"]=1
		done < <(rpm --query --package --provides "${rpm_file}" 2> /dev/null)
	done

	# collect the requirements that the converted packages do not satisfy themselves
	for rpm_file in "$@" ; do
		while read -r line ; do
			requirement="${line%% *}"
			if [[ -z ${requirement} || ${requirement} == rpmlib\(* || -n ${batch_provides[${requirement}]} ]] ; then
				continue
			fi
			required_by["${requirement}"]="${required_by[${requirement}]:+${required_by[${requirement}]}, }$(rpm --query --package --queryformat '%{name}' "${rpm_file}")"
		done < <(rpm --query --package --requires "${rpm_file}" 2> /dev/null)
	done

	# find out which of them nothing installed provides. rpm prints "no package provides X" for those.
	local -a missing=()
	if (( ${#required_by[@]} )) ; then
		while read -r line ; do
			if [[ ${line} == "no package provides "* ]] ; then
				requirement="${line#no package provides }"
				# can it be installed from a repository?
				if ! dnf -C --quiet repoquery --whatprovides "${requirement}" 2> /dev/null < /dev/null | grep -q . ; then
					missing+=("${requirement}  (needed by ${required_by[${requirement}]})")
				fi
			fi
		done < <(rpm --query --whatprovides "${!required_by[@]}" 2>&1)
	fi

	if (( ${#missing[@]} )) ; then
		echo -e '\e[31m
ERROR: The following libraries required by the converted packages are not installed and are not available from
your configured repositories:'
		printf '  - %s\n' "${missing[@]}"
		echo -e 'Install them manually (for example from the library vendor), and run this installer again.\e[96m'
		return 1
	fi
}

# Resolves, converts and installs the given packages with all their dependencies.
# Leading arguments starting with "--" are passed on to dnf, the rest are Xentara package names.
declare -a converted_rpm_files
install_packages() {
	local -a dnf_options=()
	local -a requested_packages=()
	local argument
	for argument in "$@" ; do
		if [[ ${argument} == --* ]] ; then
			dnf_options+=("${argument}")
		else
			requested_packages+=("${argument}")
		fi
	done

	resolve_packages "${requested_packages[@]}" || return 1

	if (( ${#resolved_packages[@]} == 0 )) ; then
		return 0
	fi

	if (( ${#dropped_depends[@]} )) ; then
		echo -e '\e[33m
The following Debian dependencies have no known RPM equivalent and were left out. If Xentara does not start,
install the corresponding libraries manually:'
		printf '  - %s\n' "${dropped_depends[@]}"
		echo -en '\e[96m'
	fi

	# download everything, then convert it all in one container run
	local package
	for package in "${resolved_packages[@]}" ; do
		fetch_package "${package}" || return 1
	done
	run_conversion || return 1

	# collect the results
	converted_rpm_files=()
	local rpm_file
	for package in "${resolved_packages[@]}" ; do
		if [[ -e ${convert_dir}/${package}/failed ]] ; then
			echo -e '\e[31m' > /dev/stderr
			cat "${convert_dir}/${package}/alien.log" > /dev/stderr
			echo -e "ERROR: Converting '${package}' failed.\e[96m" > /dev/stderr
			return 1
		fi

		rpm_file=$(ls "${convert_dir}/${package}"/*.rpm 2> /dev/null | head -n 1)
		if [[ -z ${rpm_file} ]] ; then
			echo -e "\e[31mERROR: No RPM was produced for '${package}'.\e[96m" > /dev/stderr
			return 1
		fi
		converted_rpm_files+=("${rpm_file}")

		if [[ -e ${convert_dir}/${package}/scripts_dropped ]] ; then
			echo -e "\e[33mWARNING: '${package}' has Debian-specific maintainer scripts (systemd/user/debconf helpers). They were not carried over, so any service or user setup they performed must be done manually.\e[96m"
		fi
	done

	check_unresolved_requirements "${converted_rpm_files[@]}" || return 1

	echo
	echo -e '\e[93mdnf install:\e[0m'
	local result=0
	sudo dnf install "${dnf_options[@]}" "${converted_rpm_files[@]}" "${system_packages[@]}" || result=$?
	echo -en '\e[96m'

	if (( result == 0 )) ; then
		post_install_setup
	fi
	return ${result}
}

#########################################
# Get the distro
#########################################

get_os_release_info() {
	local keyword="$1"
	sed -rn "s/^${keyword}=(\"([^\"]*)\"|([^\"]*))$/\2\3/p" /etc/os-release 2> /dev/null && :
}

os_release_id=$(get_os_release_info ID)
os_release_id_like=$(get_os_release_info ID_LIKE)
os_release_pretty_name=$(get_os_release_info PRETTY_NAME)

if [[ -z ${os_release_pretty_name} ]] ; then
	os_release_description='This Linux installation'
	os_release_description_2='this Linux installation'
else
	os_release_description="${os_release_pretty_name}"
	os_release_description_2="${os_release_pretty_name}"
fi

# get the Debian architecture
case "$(uname -m)" in
	x86_64 ) deb_arch=amd64 ;;
	aarch64 ) deb_arch=arm64 ;;
	armv7l ) deb_arch=armhf ;;
	* )
		echo "ERROR: The architecture '$(uname -m)' is not supported." > /dev/stderr
		exit 1
esac

#########################################
# Prepare the installation
#########################################

# We need dnf. Older systems that only have yum (e.g. CentOS 7) are not supported.
if ! command -v dnf > /dev/null ; then
	echo "ERROR: This installer requires the 'dnf' package manager, which was not found on ${os_release_description_2}.
For Debian and Ubuntu, please use xentara-installer.sh instead." > /dev/stderr
	exit 1
fi

# create a working directory, and remove it on exit
work_dir=$(mktemp -d)
# the directory where the packages are converted
convert_dir="${work_dir}/convert"
mkdir -p "${convert_dir}"
cleanup() {
	rm -rf "${work_dir}"
	echo -en '\e[0m'
}
trap cleanup EXIT

# Make terminal blue
echo -en '\e[96m'

echo
echo    ' +------------------------------------------------------------------------------------+'
echo    ' |                                                                                    |'
echo    ' |                                                                                    |'
echo    ' |    ___    ___ _______   ________   _________  ________  ________  ________         |'
echo    ' |   |\  \  /  /|\  ____\ |\   ___  \|\___   ___\\   __  \|\   __  \|\   __  \        |'
echo    ' |   \ \  \/  / | \  \__| \ \  \_|\  \|___ \  \_| \  \|\  \ \  \|\  \ \  \|\  \       |'
echo    ' |    \ \    / / \ \   __\ \ \  \\ \  \   \ \  \ \ \   __  \ \   _  _\ \   __  \      |'
echo    ' |     /     \/   \ \  \_|__\ \  \\ \  \   \ \  \ \ \  \ \  \ \  \\  \\ \  \ \  \     |'
echo    ' |    /  /\   \    \ \_______\ \__\\ \__\   \ \__\ \ \__\ \__\ \__\\__\\ \__\ \__\    |'
echo    ' |   /__/ |\ __\    \|_______|\|__| \|__|    \|__|  \|__|\|__|\|__|\|__|\|__|\|__|    |'
echo    ' |   |__|/ \|__|                                                                      |'
echo    ' |                                                                                    |'
echo    ' |                                 Xentara Installer                                  |'
echo    ' |                                                                                    |'
echo    ' |                           -----------------------------                            |'
echo    ' |                                                                                    |'
echo    ' |                                                                                    |'
echo    ' |               Please find additional information in our documentation              |'
echo -e ' |                              \e[93mhttps://docs.xentara.io\e[96m                               |'
echo    ' |                                                                                    |'
echo    ' |                                                                                    |'
echo    ' |                         You may also open a support ticket                         |'
echo -e ' |                             E-Mail: \e[93msupport@xentara.io\e[96m                             |'
echo    ' |                                                                                    |'
echo    ' +------------------------------------------------------------------------------------+'

#########################################
# Check system requirement
#########################################

# check that the system libraries the Debian 12 "bookworm" packages were built against are available
check_xentara_prerequisites() {
	check_package_version glibc 2.36 && \
	check_package_version libstdc++ 12.2 && \
	check_package_version libatomic 12.2 && \
	check_package_version openssl-libs 3.0.11 && \
	( check_package_version zlib-ng-compat 1.2.13 || check_package_version zlib 1.2.13 ) && \
	:
}

# Refresh the DNF metadata once, visibly (so that any prompt, e.g. for a repository key, can be answered).
# All later DNF queries use the cache only.
echo '
Refreshing package metadata...
'
echo -e '\e[93mdnf makecache:\e[0m'
sudo dnf makecache
echo -en '\e[96m'

echo '
Checking system requirements...'

# make descriptions for the Xentara version being installed
if [[ ${selected_repo} == PREVIEW ]] ; then
	xentara_version_description='the developer preview of Xentara'
	xentara_version_description_2='The Xentara developer preview'
elif [[ -z ${version} ]] ; then
	xentara_version_description='the latest version of Xentara'
	xentara_version_description_2='Xentara'
else
	xentara_version_description="Xentara version ${version}"
	xentara_version_description_2="Xentara ${version}"
fi

if ! check_xentara_prerequisites ; then
	echo -e '
\e[31m'"${os_release_description_2}"' does not provide the system libraries required by the Debian 12 "bookworm" packages of '"${xentara_version_description}"'
(glibc 2.36, libstdc++ 12.2, libatomic 12.2, OpenSSL 3.0.11, zlib 1.2.13 or later).

Please refer to https://docs.xentara.io/xentara/xentara_system_requirements.html for more information.\e[96m'
	exit 1
fi

# Converted packages are never officially supported
echo -en '
\e[33mXentara is not published as RPM packages. This installer converts the official Debian packages to RPM packages on
this machine. This is not an officially supported way of running '"${xentara_version_description}"' on '"${os_release_description}"'.

'"${xentara_version_description_2}"' may still run on this installation, but this is not supported by
embedded ocean GmbH unless you obtain written approval beforehand. Running Xentara on unsupported Linux
distributions without written approval from embedded ocean GmbH is not permitted.

Please also note that the converted packages are not part of a DNF repository, so they are not updated by "dnf upgrade".

What would you like to do?

'

COLUMNS=1
PS3='
Selection: '

select action in \
	'abort the installation' \
	'I have obtained written approval from embedded ocean GmbH and would like to proceed' \
	'I am installing Xentara for evaluation purposes only and understand that I am doing this at my own risk'
do
	case "${action}" in
		'abort the installation')
			exit 1
			;;

		'')
			echo -e '\e[31mPlease enter a number between 1 and 3.\e[33m'
			;;

		*)
			break
			;;
	esac
done
echo -en '\e[96m'

# Set up the repository strings
setup_repo

#########################################
# Install the conversion tools
#########################################

echo '
Installing prerequisites...
'

echo -e '\e[93mdnf install:\e[0m'
sudo dnf install wget gnupg2 xz
# gpgv is part of gnupg2 on RHEL, but a separate package on Fedora
if ! command -v gpgv > /dev/null ; then
	sudo dnf install gnupg2-verify
fi

# The conversion runs in a Debian container, because alien is not available on RHEL-family distributions.
# podman is part of the standard RHEL and Fedora repositories.
if ! container_engine=$(find_container_engine) ; then
	sudo dnf install podman
	container_engine=podman
fi
echo -en '\e[96m'

#########################################
# Get credentials, if necessary
#########################################

# see if we need developer credentials
if ${need_developer_credentials} ; then

	# get credential for the developer Repo
	echo 'Please enter your Xentara developer user name and password to access the Xentara developer preview.'

	# get the credentials
	get_credentials "${main_repo_url}" user_name password
	# remember them for the downloads
	store_credentials "${user_name}" "${password}" "${main_repo_url}"

# see if we need customer credentials. This is not necessary if we already have developer credentials,
# because the two are always the same
elif ${need_customer_credentials} ; then
	# get credential for the developer Repo
	echo "Please enter the user name for '${customer}' to access your customer repository."

	# loop until the user name and password is valid
	get_credentials "${customer_repo_url}" user_name password "${customer}"
	# remember them for the downloads
	store_credentials "${user_name}" "${password}" "${customer_repo_url}"
fi

#########################################
# Download the repository metadata
#########################################

# download the signing keyring. It is only used to verify the repository metadata, so it is kept in the work directory.
echo '
Downloading embedded ocean GmbH signing key...'
keyring_path="${work_dir}/xentara-archive-keyring.gpg"
download_file "https://download.xentara.io/apt/support-files/xentara-archive-keyring.gpg" "${keyring_path}" || exit 1

# gpgv should not touch the user's real GnuPG directory
export GNUPGHOME="${work_dir}/gnupg"
mkdir -m 700 "${GNUPGHOME}"

echo '
Reading and verifying the package lists...'
release_file_invalid=false
for url in "${repo_urls[@]}" ; do
	for suite in "${repo_suites[@]}" ; do
		for component in "${repo_components[@]}" ; do
			collect_packages "${url}" "${suite}" "${component}"
		done
	done
done

if (( ${#pkg_versions[@]} == 0 )) ; then
	echo -e '\e[31mERROR: No packages were found in the Xentara repositories for '"${suite_prefix}"'.\e[96m' > /dev/stderr
	exit 1
fi

#########################################
# Install Xentara
#########################################

# check the install type
if [[ ${install_type} == XENTARA ]] ; then
	if is_package_installed xentara ; then
		echo '
The Xentara base system is already installed.'

		# make sure that the group, library path etc. are set up, even if an earlier version of this installer
		# (or a failed install) did not do it
		post_install_setup
	else
		echo '
Installing Xentara...
'

		# install xentara
		install_packages xentara || exit 1

		echo '
The Xentara base system has been successfully installed.'
	fi
fi

#########################################
# Install Skills
#########################################

# check the install type
if [[ ${install_type} == XENTARA ]] ; then
	# no longer fail on first error
	set +e

	# collect all the skills
	collect_skills
	make_skill_selection

	# tell the user about skills that are not offered
	if (( ${#unsupported_skills[@]} )) ; then
		echo -e '\e[33m
The following skills are not available on RPM-based distributions, because they need Debian libraries that are
not compatible with the system libraries:'
		printf '%s\n' "${unsupported_skills[@]}" | sort | sed 's/^/  - /'
		echo -en '\e[96m'
	fi

	# print a message if all skills have been installed
	if (( ${#skill_selections[@]} == 0 )) ; then
		echo '
All avaiable skills are already installed.'
	fi

	COLUMNS=1
	PS3='
Selection: '

	while (( ${#skill_selections[@]} )); do

		# print the header
		if (( ${#installed_skill_packages[@]} )) ; then
			echo '
Installed skills:
-----------------'
		print_installed_skills
		echo '
Select additional skills to install:
------------------------------------'
	else
		echo '
Select skills to install:
-------------------------'
		fi

		# allow the user to select additional skills
		select skill in \
			"${skill_selections[@]}" \
			'all' \
			'none (exit)'
		do
			case "${skill}" in
				'all')
					echo '
Installing all available skills...
'
					if install_packages --assumeyes "${available_skill_packages[@]}" ; then
						echo
						echo "${#available_skill_packages[@]} skills have been successfully installed."
					else
						echo -e '\e[31mInstalling the skills failed.\e[96m'
					fi
					break 2
					;;
				'none (exit)')
					break 2
					;;
				'')
					echo -e "\e[31mPlease enter a number between 1 and $(((${#skill_selections[@]} + 2))).\e[96m"
					break
					;;
				*)
					package="${skill_packages[${skill}]}"

					echo
					echo "
Installing '${package}'...
"

					if install_packages --assumeyes "${package}" ; then
						echo
						echo "Skill '${package}' has been successfully installed."

						filter_array skill_selections "${skill}"
						filter_array available_skill_packages "${package}"

						installed_skill_packages+=( "${package}" )
					else
						echo -e "\e[31mInstalling '${package}' failed.\e[96m"
					fi

					break
					;;
			esac
		done
	done

	echo -e '
You can use the \e[93mdnf\e[96m utility to remove Xentara and Xentara skills (\e[93mdnf remove\e[96m). To upgrade, run this installer again after removing the old packages.
'
fi

#########################################
# Install The Xentara licence server
#########################################

# check the install type
if [[ ${install_type} == LICENCE_SERVER ]] ; then
	if is_package_installed xentara-licence-server ; then
		echo '
The Xentara licence server is already installed.'
	else
		echo '
Installing the Xentara licence server...
'

		# install the licence server
		install_packages xentara-licence-server || exit 1

		echo '
The Xentara licence server has been successfully installed.'

		echo -e '
You can use the \e[93mdnf remove\e[96m command to remove the Xentara licence server.
'
	fi
fi
