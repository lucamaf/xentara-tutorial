#!/bin/bash

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
Interactive installer for Xentara and related packages

  --preview             Install the developer preview of Xentara. This option requires a Xentara
                        developer account
  --testing             Include unsupported test versions of Xentara skills.
                        \e[31mWARNING: Software installed using this option is intended to be used for
                        testing and evaluation purposes only. There is no warranty, express or implied,
                        to the extent permissible by law for Software installed using this options. Test
                        versions of Xentara or Xentara skills must not be used in productive systems.\e[0m 
  --customer=CUSTOMER   Show customer-specific packages for customer 'CUSTOMER'.
  --version=MAJOR.MINOR Install a specific version of Xentara.
  --internal            For use by embedded ocean GmbH only. Do not use this option.
  --debug               For use by embedded ocean GmbH only. Do not use this option.
  --licence-server      Install the Xentara floating licence server instead of installing Xentara
  -h, --help            Show this message and exit.

You can only specify at most one of '--preview', '--testing', and '--debug'"
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
				usage_error "'${version}' is not a valid version number. The version number must have the form 'MAJOR.MINOR', for example '1.2' or '2.0'"
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

# Set up to use the release repo
use_release_repo() {
	# set the URLs
	main_apt_url=https://download.xentara.io/apt/
	customer_url_base=https://download.xentara.io/customers/

	# set the suites
	if [[ -z ${version} ]] ; then
		apt_suites=(${apt_suite_prefix}stable)
	else
		apt_suites=(${apt_suite_prefix}${version})
	fi

	# set other options
	apt_components=(non-free misc)
	need_developer_credentials=false
}

# Set up to use the preview repo
use_preview_repo() {
	# set the URLs
	main_apt_url=https://developer.xentara.io/apt/
	customer_url_base=https://developer.xentara.io/customers/

	# always use the prerelease suite
	apt_suites=(${apt_suite_prefix}prerelease)

	# set other options
	apt_components=(non-free misc)
	need_developer_credentials=true
}

# Set up to use the testing repo
use_testing_repo() {
	# set the URLs
	main_apt_url=https://download.xentara.io/apt/
	customer_url_base=https://download.xentara.io/customers/

	# set the suites
	if [[ -z ${version} ]] ; then
		apt_suites=(${apt_suite_prefix}stable ${apt_suite_prefix}testing)
	else
		apt_suites=(${apt_suite_prefix}${version} ${apt_suite_prefix}${version}-testing)
	fi

	# set other options
	apt_components=(non-free misc)
	need_developer_credentials=false
}

# Set up to use the internal repo
use_internal_repo() {
	# set the URLs
	main_apt_url=http://eog-build.xentara.internal/repos/apt/
	customer_url_base=

	# set the suites
	if [[ -z ${version} ]] ; then
		apt_suites=(${apt_suite_prefix}prerelease)
	else
		apt_suites=(${apt_suite_prefix}${version} ${apt_suite_prefix}${version}-testing)
	fi

	# set other options
	apt_components=(non-free misc)
	need_developer_credentials=false
}

# Set up to use the debug repo
use_debug_repo() {
	main_apt_url=http://eog-build.xentara.internal/repos/apt/
	customer_url_base=
	apt_suites=(prerelease prerelease-debug)

	# set the suites
	if [[ -z ${version} ]] ; then
		apt_suites=(${apt_suite_prefix}prerelease ${apt_suite_prefix}prerelease-debug)
	else
		apt_suites=(${apt_suite_prefix}${version} ${apt_suite_prefix}${version}-debug ${apt_suite_prefix}${version}-testing ${apt_suite_prefix}${version}-debug-testing)
	fi

	# set other options
	apt_components=(non-free misc)
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
		customer_apt_url=
		need_customer_credentials=false
	else
		# see if we have a separate URL
		if [[ -z ${customer_url_base} ]] ; then
			customer_apt_url=
			add_customer_suites apt_suites "${customer}"
			need_customer_credentials=false
		else
			customer_apt_url="${customer_url_base}${customer}/apt/"
			need_customer_credentials=true
		fi
	fi

	# make the list of repositories
	apt_urls=("${main_apt_url}")
	if [[ ! -z ${customer_apt_url} ]] ; then
		apt_urls+=("${customer_apt_url}")
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

# create an authentication file owned by root
create_auth_conf_file() {
	# get the user name and password. APT does not seem to support any encoding of the password. 
	local user_name="$1"
	local password="$2"

	# get the destination file name
	local url="$3"
		
	# get the base URL
	local base_url=$(get_base_url "${url}")
	# get the pure host name
	local host_name="${base_url#+([-a-zA-Z0-9+.])://}"

	# make the file path
	local file_path="/etc/apt/auth.conf.d/${host_name}.conf"

	# Create a .netrc type entry and write it to a file as root. We use --preserve=mode, because /dev/stdin conveniently already has mode 0600, which is what we need.
	# copy it to the correct place. we do not use mv, so that the owner is set to root:root.
	echo "machine ${base_url} login ${user_name} password ${password}" | sudo cp --preserve=mode --remove-destination --no-target-directory /dev/stdin "${file_path}"
}

# downloads a file. Writes the file's contents to stdout
download_file() {
	# get the URL
	local url="$1"

	# create a temporary log file for wget. We use a log file, because we only want to show the output on error.
	local log_file_path=$(mktemp)

	# dump the log file on error (in red)
	trap "{ echo -en '\e[31m' ; cat \"${log_file_path}\"; echo -en '\e[96m'; } > /dev/stderr" ERR
	# delete the log file on return, and on exit
	trap "rm -f '${log_file_path}' ; trap - RETURN EXIT ERR" RETURN EXIT

	# download the file
	echo "${url}" | wget --output-file="${log_file_path}" --no-verbose --input-file=- --no-netrc --output-document=-
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

# downloads a file and installs it as root
install_file() {
	# get the URL
	local url="$1"
	# get the target file name
	local target_file="$2"

	# download the file, and save it to the target file as root
	download_file "${url}" | sudo cp --no-preserve=mode --remove-destination --no-target-directory /dev/stdin "${target_file}"
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

# gets the status of a package
get_package_status() {
	dpkg-query --show --showformat='${Status}' "$1" 2> /dev/null || : 
}

# check whether a package is installed. Also checks the +debug version.
is_package_installed() {
	# get the package
	local package="$1"


	# get the status
	[[ \
		"$(get_package_status "${package}")" == "install ok installed" || \
		"$(get_package_status "${package}+debug")" == "install ok installed" \
	]]
}

# check that a package version is available
check_package_version() {
	# get the package
	local package="${1//+/\\+}"
	# get the desired version
	local desired_version="$2"

	# get the available version
	local available_version=$(LANG=C apt-cache policy "^${package}$" | sed -rn 's/^[[:space:]]*Candidate:[[:space:]]*(.*)$/\1/p')

	# compare the versions
	dpkg --compare-versions "${available_version}" ge "${desired_version}" 2> /dev/null && :
}

#########################################
# Helper functions for collecting the skills
#########################################

# function to declare a skill
declare -a installed_skill_packages
declare -a available_skill_packages
declare -A skill_descriptions
max_skill_package_name_length=0

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

# function to get the skills from a repo
declare -a skill_selections
declare -A skill_packages
collect_skills() {
	# get the name of the repo and the component
	local repo="$1"
	local suite="$2"
	local component="$3"
	
	# remove URL scheme from the repo name
	repo=${repo#+([-a-zA-Z0-9+.])://}
	# remove the trailing slash
	repo=${repo%/}
	
	# get the architecture
	local arch=$(dpkg --print-architecture)
	
	# make the path of the repo package list
	local package_list="/var/lib/apt/lists/${repo//\//_}_dists_${suite//\//_}_${component}_binary-${arch}_Packages"
	
	# make sure the file exists
	if [[ ! -r ${package_list} ]] ; then
		return
	fi
	
	# read the package list
	local package=""
	local description=""
	while read -r line ; do
		# check if it is an empty line, which is the separator
		if [[ -z ${line} ]] ; then
			add_skill "${package}" "${description}"
			package=""
			description=""
		fi
		
		# interpret the line
		case "${line}" in
			Package:* )
				package="${line/#Package:+( )/}"
				;;
			Description:* )
				description="${line/#Description:+( )/}"
				;;
				
			* )
		esac
	done < "${package_list}"
	
	# add any packages that were left over from the last block in the file
	add_skill "${package}" "${description}"
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
# Prepare the installation
#########################################

# Make terminal blue
echo -en '\e[96m'
# revert the terminal on exit
trap "echo -en '\e[0m'" EXIT

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

# install require packages
echo '
Installing prerequisites...
'

echo -e '\e[93mapt install:\e[0m'
sudo apt install --no-upgrade wget dpkg
echo -en '\e[96m'

#########################################
# Helper functions for version checking
#########################################

# check that distro is supported for the latest version of Xentara
check_xentara_distro() {
	if [[ ${os_release_distro} == debian ]] ; then
		[[ ${os_release_codename} == trixie || ${os_release_codename} == bookworm ]] && :
	elif [[ ${os_release_distro} == ubuntu ]] ; then
		[[ ${os_release_codename} == resolute || ${os_release_codename} == noble ]] && :
	else
		false && : 
	fi
}

# check that distro is supported for Xentara 1.x
check_xentara_distro_1_x() {
	if [[ ${os_release_distro} == debian ]] ; then
		[[ ${os_release_codename} == bullseye ]] && :
	elif [[ ${os_release_distro} == ubuntu ]] ; then
		[[ ${os_release_codename} == focal ]] && :
	else
		false && : 
	fi
}

# prints the supported distros for the latest version of Xentara
print_xentara_distros() {
	echo \
'- Debian 13 "trixie" or Debian 12 "bookworm"
- Ubuntu 26.04 LTS (Resolute Raccoon) or Ubuntu 24.04 LTS (Noble Numbat)
- Raspberry Pi OS based on Debian 13 "trixie" or Debian 12 "bookworm"'
}

# prints the supported distros for Xentara 1.x
print_xentara_distros_1_x() {
	echo \
'- Debian 11 "bullseye"
- Ubuntu 20.04 LTS (Focal Fossa)
- Raspberry Pi OS based on Debian 11 "bullseye"'
}

# get the available suite prefixes for the latest version of Xentara
get_xentara_suite_prefixes() {
	echo "debian-trixie debian-bookworm ubuntu-resolute ubuntu-noble"
}

# get the available suite prefixes for the latest version of Xentara
get_xentara_suite_prefixes_1_x() {
	echo "debian-bullseye ubuntu-focal"
}

# check that the packages for the latest version of Xentara are available
check_xentara_prerequisites() {
	check_package_version libc6 2.36 && \
	check_package_version libstdc++6 12.2 && \
	check_package_version libatomic1 12.2 && \
	check_package_version libssl3 3.0.11 && \
	check_package_version zlib1g 1:1.2.13 && \
	:
}

# check that the packages for Xentara 1.x are available
check_xentara_prerequisites_1_x() {
	check_package_version libc6 2.31 && \
	check_package_version libstdc++6 10.2 && \
	check_package_version libatomic1 10.2 && \
	:
}

#########################################
# Get the distro
#########################################

get_os_release_info() {
	local keyword="$1"
	sed -rn "s/^${keyword}=(\"([^\"]*)\"|([^\"]*))$/\2\3/p" /etc/os-release 2> /dev/null && :
}

os_release_distro=$(get_os_release_info ID)
os_release_codename=$(get_os_release_info VERSION_CODENAME)
os_release_pretty_name=$(get_os_release_info PRETTY_NAME)

if [[ -z os_release_pretty_name ]] ; then
	os_release_description='This Linux installation'
	os_release_description_2='this Linux installation'
else
	os_release_description="${os_release_pretty_name}"
	os_release_description_2="${os_release_pretty_name}"
fi

# get the suite prefix
apt_suite_prefix="${os_release_distro}-${os_release_codename}/"

# map known suites
declare -A distro_to_pretty_distro=(
	['debian-trixie']='Debian 13 "trixie"'
	['debian-bookworm']='Debian 12 "bookworm"'
	['debian-bullseye']='Debian 11 "bullseye"'
	['ubuntu-resolute']='Ubuntu 26.04 LTS (Resolute Raccoon)'
	['ubuntu-noble']='Ubuntu 24.04 LTS (Noble Numbat)'
	['ubuntu-focal']='Ubuntu 20.04 LTS (Focal Fossa)'
)
# make a reverse map as well
declare -A pretty_distro_to_distro
for key in "${!distro_to_pretty_distro[@]}" ; do
	value="${distro_to_pretty_distro[${key}]}"
	pretty_distro_to_distro[${value}]="${key}"
done

#########################################
# Check system requirement
#########################################

# install require packages
echo '
Checking system requirements...'

# function to check the requirements
check_system_requirements() {
	# make descriptions for the Xentara version being installed
	if [[ ${selected_repo} == PREVIEW ]] ; then
		local xentara_version_description='the developer preview of Xentara'
		local xentara_version_description_2='The Xentara developer preview'
	elif [[ -z ${version} ]] ; then
		local xentara_version_description='the latest version of Xentara'
		local xentara_version_description_2='Xentara'
	else
		local xentara_version_description="Xentara version ${version}"
		local xentara_version_description_2="Xentara ${version}"
	fi

	# check which version we are installing
	if dpkg --compare-versions "${version}" lt-nl "2.0" ; then
		local xentara_version_variant=_1_x
	else
		local xentara_version_variant=
	fi

	## check whether the distro is supported
	if ! check_xentara_distro${xentara_version_variant} ; then
		if ! check_xentara_prerequisites${xentara_version_variant} ; then
			# print an error message
			echo -e '
\e[31m'"${os_release_description_2}"' does not fulfill the system requirements for installing '"${xentara_version_description}"'.

'"${xentara_version_description_2}"' requires one of the following Linux distributions:

'"$(print_xentara_distros${xentara_version_variant})"'

Please refer to https://docs.xentara.io/xentara/xentara_system_requirements.html for more information.\e[96m'

			# see if an older version of Xentara will work
			if [[ ${xentara_version_variant} != _1_x ]] && check_xentara_prerequisites_1_x ; then
				echo -en '\e[33m
You have the option of installing an older version of Xentara. What would you like to do?

'

		COLUMNS=1
		PS3='
Selection: '

				select action in \
					'abort the installation' \
					'install Xentara version 1.2'
				do
					case "${action}" in
						'install Xentara version 1.2')
							# select the version
							if [[ ${selected_repo} == PREVIEW ]] ; then
								selected_repo=()
							fi
							version=1.2
							return 1
							;;

						'')
							echo -e '\e[31mPlease enter a number between 1 and 2.\e[33m'
							;;

						*)
							exit 1
							;;
					esac
				done
			fi

			# no further options possible
			exit 1
		else
			# print an error message
			echo -en '
\e[33m'"${xentara_version_description_2}"' is not officially supported on '"${os_release_description}"'.

The following Linux distributions are officially supported for '"${xentara_version_description}"':

'"$(print_xentara_distros${xentara_version_variant})"'

'"${xentara_version_description_2}"' may still run on this installation, but this is not supported by
embedded ocean GmbH unless you obtain written approval beforehand. Running Xentara on unsupported Linux
distributions without written approval from embedded ocean GmbH is not permitted.

What would you like to do?

'

			# offer to proceed with the installation under certain circumstances
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
		
			echo -en '\e[96m
Which distribution would you like to use for the installation? Pick the distribution that most closely resembles
your Linux installation.

'
		
			# make pretty names
			local -a avaliable_distros=()
			for key in $(get_xentara_suite_prefixes${xentara_version_variant}) ; do
				avaliable_distros+=( "${distro_to_pretty_distro[${key}]}" )
			done

			# select the suite
			local distro
			select distro in \
				"${avaliable_distros[@]}" \
				'abort the installation'
			do
				case "${distro}" in
					'abort the installation')
						exit 1
						;;

					'')
						echo -e "\e[31mPlease enter a number between 1 and $(((${#avaliable_distros[@]} + 1))).\e[96m"
						;;

					*)
						apt_suite_prefix="${pretty_distro_to_distro[${distro}]}/"
						break
				esac
			done

		fi
	fi

	return 0
}

# loop until we are done
while ! check_system_requirements ; do :; done

# Set up the repository strings
setup_repo

#########################################
# Get credentials, if necessary
#########################################

# see if we need developer credentials
if ${need_developer_credentials} ; then

	# get credential for the developer Repo
	echo 'Please enter your Xentara developer user name and password to access the Xentara developer preview.'

	# get the credentials
	get_credentials "${main_apt_url}" user_name password
	# create the configuration file
	create_auth_conf_file "${user_name}" "${password}" "${main_apt_url}"

# see if we need customer credentials. This is not necessary if we already have developer credentials,
# because the two are always the same
elif ${need_customer_credentials} ; then
	# get credential for the developer Repo
	echo "Please enter the user name for '${customer}' to access your customer repository."

	# loop until the user name and password is valid
	get_credentials "${customer_apt_url}" user_name password "${customer}"
	# create the configuration file
	create_auth_conf_file "${user_name}" "${password}" "${customer_apt_url}"
fi

#########################################
# Setup the APT environment
#########################################

# download the keyring
echo '
Downloading embedded ocean GmbH signing key...'
install_file "https://download.xentara.io/apt/support-files/xentara-archive-keyring.gpg" "/usr/share/keyrings/xentara-archive-keyring.gpg"

# remove the old keyring for security reasons
if [[ -f  "/etc/apt/trusted.gpg.d/embedded-ocean-archive.gpg" ]] ; then
	sudo rm -f "/etc/apt/trusted.gpg.d/embedded-ocean-archive.gpg"
fi

# see if we should use a list file

# create the list file
echo '
Adding repositories to APT configuration...
'
sources_file_path="/etc/apt/sources.list.d/xentara.sources"

# make the specs
repository_specs=""
for url in "${apt_urls[@]}" ; do
	# add a separator, if necessary
	if [[ ! -z ${repository_specs} ]] ; then
		repository_specs+="
"
	fi

	# add the header
	repository_specs+="\
Types: deb
URIs: ${url}
Suites: ${apt_suites[*]}
Components: ${apt_components[*]}
Signed-By: /usr/share/keyrings/xentara-archive-keyring.gpg
"
done
echo -n "${repository_specs}" | sudo cp --no-preserve=mode --remove-destination --no-target-directory /dev/stdin "${sources_file_path}"

# remove any old xentara.list file
sudo rm -f "/etc/apt/sources.list.d/xentara.list"

# update the APT cache
echo -e '\e[93mapt update:\e[0m'
sudo apt update
echo -en '\e[96m'

# install the keyring
echo '
Updating archive keyring...
'

echo -e '\e[93mapt install:\e[0m'
sudo apt install xentara-archive-keyring
echo -en '\e[96m'

#########################################
# Install Xentara
#########################################

# check the install type
if [[ ${install_type} == XENTARA ]] ; then
	if is_package_installed xentara ; then
		echo '
The Xentara base system is already installed.'
	else
		echo '
Installing Xentara...
'

		# install xentara
		echo -e '\e[93mapt install:\e[0m'
		sudo apt install --no-upgrade xentara
		echo -en '\e[96m'

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
	for url in "${apt_urls[@]}" ; do
		for suite in "${apt_suites[@]}" ; do
			for component in "${apt_components[@]}" ; do
				collect_skills "${url}" "${suite}" "${component}"
			done
		done
	done
	make_skill_selection

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
					echo
					echo -e '\e[93mapt install:\e[0m'
					sudo apt --yes install "${available_skill_packages[@]}"
					echo -en '\e[96m'

					echo
					echo "${#available_skill_packages[@]} skills have been successfully installed."
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

					echo -e '\e[93mapt install:\e[0m'
					sudo apt --yes install "${package}"
					echo -en '\e[96m'

					echo
					echo "Skill '${package}' has been successfully installed."
				
					filter_array skill_selections "${skill}"
					filter_array available_skill_packages "${package}"

					installed_skill_packages+=( "${package}" )
		
					break
					;;
			esac
		done
	done

	# fail on first error again
	set +e

	echo -e '
You can use the \e[93mapt\e[96m utility to install, remove, or upgrade Xentara and Xentara skills. Type \e[93mapt --help\e[96m or \e[93mman apt\e[96m for more information.
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

		# install xentara
		echo -e '\e[93mapt install:\e[0m'
		sudo apt install --no-upgrade xentara-licence-server
		echo -en '\e[96m'

		echo '
The Xentara licence server has been successfully installed.'

		echo -e '
You can use the \e[93mapt\e[96m utility to remove, or upgrade the Xentara licence server. Type \e[93mapt --help\e[96m or \e[93mman apt\e[96m for more information.
'
	fi
fi
