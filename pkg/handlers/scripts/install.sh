#!/bin/bash

DEFAULT_DIR="/usr/local/bin"
INSECURE="{{ .Insecure }}"
OUT_DIR="{{ if .MoveToPath }}${DEFAULT_DIR}{{ else }}$(pwd){{ end }}"
PROG="{{ .Program }}"
RELEASE="{{ .Release }}"
TMP_DIR=$(mktemp -d || mktemp -d -t /tmp)
USER="{{ .User }}"

function print_help {
	echo "{{ .Program }} installer script."
	echo ""
	echo "USAGE:"
	echo "   $(basename "$0") [OPTIONS]"
	echo "   $(basename "$0") [OPTIONS] -i PATH"
	echo "   $(basename "$0") [OPTIONS] -s PASSWORD"
	echo ""
	echo "ARGS:"
	echo "   PASSWORD  A valid sudo password for the current running user"
	echo "   PATH      A directory to install into"
	echo ""
	echo "OPTIONS:"
	echo "   -h --help              print this help message"
	echo "   -i --install <PATH>    use PATH as the install directory"
	echo "   -s --sudo <PASSWORD>   use sudo with PASSWORD if needed"
}

# Parse the arguments. The "-" option is used to parse long options.
while getopts ":hs:i:-:" optchar; do
	case "${optchar}" in
		h)
			print_help
			exit 0
			;;
		s)
			PASSWORD="${OPTARG}"
			;;
		i)
			OUT_DIR="${OPTARG}"
			;;
		-)
			case "${OPTARG}" in
				sudo)
					OPTARG="${!OPTIND}" # expand the current OPTIND 
					OPTIND=$(( $OPTIND + 1 )) # increment the option index
					PASSWORD=${OPTARG}
					;;
				sudo=*)
					OPTARG="${OPTARG#*=}" # match and delete from the beginning of OPTARG to "="
					PASSWORD=${OPTARG}
					;;
				install)
					OPTARG="${!OPTIND}"
					OPTIND=$(( $OPTIND + 1 ))
					OUT_DIR=${OPTARG}
					;;
				install=*)
					OPTARG="${OPTARG#*=}"
					OUT_DIR=${OPTARG}
					;;
				*)
					echo "unknown option -${OPTARG}"
					print_help
					exit 1
					;;
				esac
				;;
		*)
			echo "unknown option $opt $OPTARG"
			print_help
			exit 1
			;;
	esac
done

# Cleanup temporary files if they exist and return to the starting directory.
# This is trapped on EXIT signals to ensure it is always called on failures.
function cleanup {
	popd &> /dev/null
	if [[ -d "${TMP_DIR}" ]]; then
		rm -rf "${TMP_DIR}"
	fi
}
trap cleanup EXIT

# Print a big error message.
function fail {
	msg="!! Error: $1 !!"
	len=${#msg}
	border=$(printf "%*s\n" "$len" | tr " " "!")

	echo ""
	echo "$border"
	echo "$msg" 1>&2
	echo "$border"
	echo ""
	exit 1
}

# Prompt the user if they would like to create the output directory.
function prompt_create_dir {
	if [[ ! -t 0 && ! -t /dev/stdin ]]; then
		return false
	fi

	echo ""
	echo "The output directory ${OUT_DIR} does not exist, should it be created with sudo?"
	read -p "Y or N? " -n 1 -r REPLY
	echo ""
	case "${REPLY}" in
		y|Y)
			if [[ -z "${PASSWORD+x}" ]]; then
				sudo mkdir -p "${OUT_DIR}" &> /dev/null || fail "could not create directory ${OUT_DIR}"
			else
				sudo -S mkdir -p "${OUT_DIR}" <<< "${PASSWORD}" &> /dev/null
			fi
			;;
		*)
			fail "cannot proceed without creating ${OUT_DIR} or specifying a writeable directory with '-i'"
	esac
}

# Check that the environment supports the install.
function check_env {
	[[ ! -z "${BASH_VERSION+x}" ]] || fail "Please use bash instead"

	# Check $HOME/.local/bin and /usr/bin if /usr/local/bin doesn't exist.
	if [[ "${OUT_DIR}" = "${DEFAULT_DIR}" && ! -d "${OUT_DIR}" ]]; then
		if [[ -d "/usr/bin" ]]; then
			OUT_DIR="/usr/bin"
		elif [[ -d "${HOME}/.local/bin" ]]; then
				OUT_DIR="${HOME}/.local/bin"
			else
				fail "could not find a valid output directory: ${OUT_DIR} /usr/bin ${HOME}/.local/bin"
		fi
	fi

	# Check that the output directory exists.
	[[ -d "${OUT_DIR}" ]] || prompt_create_dir || fail "output directory ${OUT_DIR} does not exist"

	# Check for needed utilities.
	command -v find &> /dev/null || fail "find not installed"
	command -v xargs &> /dev/null || fail "xargs not installed"
	command -v sort &> /dev/null || fail "sort not installed"
	command -v tail &> /dev/null || fail "tail not installed"
	command -v cut &> /dev/null || fail "cut not installed"
	command -v du &> /dev/null || fail "du not installed"

	# Check for a download utility.
	if command -v curl &> /dev/null; then
		GET_PROG="curl"
		if [[ ${INSECURE} = "true" ]]; then
			GET_OPTS=("--insecure")
		fi
		GET_OPTS+=("--fail" "-#" "-L")
	elif command -v wget &> /dev/null; then
		GET_PROG="wget"
		if [[ ${INSECURE} = "true" ]]; then
			GET_OPTS=("--no-check-certificate")
		fi
		GET_OPTS+=("-qO-")
	fi
	[[ ! -z "${GET_PROG+x}" || ! -z "${GET_OPTS+x}" ]] || fail "curl and wget are not installed"

	# Check the OS and architecture.
	case $(uname -s) in
		Darwin)
			OS="darwin"
			;;
		Linux)
			OS="linux"
			;;
		*)
			fail "unsupported OS $(uname -s)"
			;;
	esac
	[[ ! -z "${OS+x}" ]] || fail "could not determine the OS"

	case $(uname -m) in
		"amd64" | "x86_64")
			ARCH="amd64"
			;;
		"arm64" | "aarch64")
			ARCH="arm64"
			;;
		"arm")
			ARCH="arm"
			;;
		"i386")
			ARCH="386"
			;;
		*)
			fail "unsupported architecture $(uname -m)"
	esac
	[[ ! -z "${ARCH+x}" ]] || fail "could not determine the architecture"

	# Check for the current OS + arch combination in the available assets.
	# NOTE: the case statements are built by the templating engine by ranging
	#   over the set of assets and creating an OS_ARCH case that assigns that
	#   asset's URL and file type.
	case "${OS}_${ARCH}" in
	  {{ range .Assets }}
		{{ .OS }}_{{ .Arch }})
			URL="{{ .URL }}"
			FTYPE="{{ .Type }}"
			;;
		{{ end }}
		*)
			fail "No asset found for platform ${OS}-${ARCH}"
			;;
	esac
	[[ ! -z "${URL+x}" || ! -z "${FTYPE+x}" ]] || fail "could not find the right download URL and type"

	# Check that the assets can be extracted.
	case "${FTYPE}" in
		".gz")
			command -v gzip &>/dev/null || fail "gzip is not installed"
			;;
		".tar.gz")
			command -v tar &>/dev/null || fail "tar is not installed"
			;;
		".zip")
			command -v unzip &>/dev/null || fail "zip is not installed"
			;;
		"")
			;;
		*)
			fail "unsupported file type ${FTYPE}"
	esac
}

function install {
	echo "Downloading ${USER}/${PROG} ${RELEASE} (${URL})..."

	# Download and extract the binary to the temporary directory.
	pushd $TMP_DIR &> /dev/null

	case "${FTYPE}" in
		".gz")
			if [[ "${GET_PROG}" = "curl" ]]; then
		    curl "${GET_OPTS[@]}" "${URL}" | gzip -d - > "${PROG}" || fail "download and extraction failed"
			else
			  wget "${GET_OPTS[@]}" "${URL}" | gzip -d - > "${PROG}" || fail "download and extraction failed"
			fi
			;;
		".tar.gz")
			if [[ "${GET_PROG}" = "curl" ]]; then
			  curl "${GET_OPTS[@]}" "${URL}" | tar xzf - > "${PROG}" || fail "download and extraction failed"
			else
			  wget "${GET_OPTS[@]}" "${URL}" | tar xzf - > "${PROG}" || fail "download and extraction failed"
			fi
			;;
		".zip")
			tmp_file=$(basename $URL)
			if [[ "${GET_PROG}" = "curl" ]]; then
			  curl "${GET_OPTS[@]}" "${URL}" > "${tmp_file}" && unzip -o -qq "${tmp_file}" || fail "download and extraction failed"
			else
			  wget "${GET_OPTS[@]}" "${URL}" > "${tmp_file}" && unzip -o -qq "${tmp_file}" || fail "download and extraction failed"
			fi
			rm tmp_file
			;;
		"")
			if [[ "${GET_PROG}" = "curl" ]]; then
			  curl "${GET_OPTS[@]}" "${URL}" > "{{ .Program }}_${OS}_${ARCH}" || fail "download failed"
			else
			  wget "${GET_OPTS[@]}" "${URL}" > "{{ .Program }}_${OS}_${ARCH}" || fail "download failed"
			fi
			;;
		*)
			fail "unknown file type ${FTYPE}"
	esac

	echo "{{ if .MoveToPath }}Installing{{ else }}Moving{{ end }} to ${OUT_DIR}"

	# BUG: this will fail on a payload with unrelated files larger than the target binary.
	# TODO: will there ever be unrelated files in the payload? Why not grab the _only_ file?
	TMP_BIN=$(find . -type f | xargs du | sort -n | tail -n 1 | cut -f 2)
	if [ ! -f "${TMP_BIN}" ]; then
		fail "could not find downloaded binary"
	fi

	#ensure its larger than 2MB
	# BUG: this check relies on the current state of the go compiler and binary optimization tools.
	if [[ $(du -m "${TMP_BIN}" | cut -f1) -lt 2 ]]; then
		fail "resulting file is smaller than 2MB, not a go binary"
	fi

	popd &> /dev/null

	#move into PATH or cwd
	chmod +x "${TMP_DIR}/${TMP_BIN}" || fail "chmod +x failed"

	if ! mv "${TMP_DIR}/${TMP_BIN}" "${OUT_DIR}/kubectl-${PROG}" &>/dev/null; then
		if [[ -z "${PASSWORD+x}" ]]; then
			if [[ -t 0 || -t /dev/stdin ]]; then
				sudo mv "${TMP_DIR}/${TMP_BIN}" "${OUT_DIR}/kubectl-${PROG}" &> /dev/null || fail "move failed"
			else
				fail "output directory ${OUT_DIR} cannot be written to, no sudo password provided, and stdin cannot be read"
			fi
		else
			sudo -S mv "${TMP_DIR}/${TMP_BIN}" "${OUT_DIR}/kubectl-${PROG}" &> /dev/null <<< "${PASSWORD}" || fail "move failed"
		fi
	fi
	echo "{{ if .MoveToPath }}Installed at{{ else }}Downloaded to{{ end }} $OUT_DIR/kubectl-$PROG"
}

check_env
install
