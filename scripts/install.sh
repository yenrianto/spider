#!/bin/bash
set -e

# Spider CLI Installer
# Usage: curl -fsSL https://spiderme.org/install.sh | bash
#   Or: curl -fsSL https://spiderme.org/install.sh | bash -s -- --version latest
#   Or: curl -fsSL https://spiderme.org/install.sh | bash -s -- --version 0.1.0 --install-dir /custom/path

SPIDER_REPO="llllOllOOll/spider"
GITHUB_API="https://api.github.com/repos/${SPIDER_REPO}/releases/latest"
INSTALL_DIR="${SPIDER_INSTALL_DIR:-$HOME/.local/bin}"
VERSION="latest"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info() {
    echo -e "${GREEN}[spider]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[spider]${NC} $1"
}

error() {
    echo -e "${RED}[spider]${NC} $1" >&2
    exit 1
}

# Parse arguments
parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --version)
                if [ -z "$2" ] || [ "${2#-}" != "$2" ]; then
                    error "--version requires a value"
                fi
                VERSION="$2"
                shift 2
                ;;
            --install-dir)
                if [ -z "$2" ] || [ "${2#-}" != "$2" ]; then
                    error "--install-dir requires a value"
                fi
                INSTALL_DIR="$2"
                shift 2
                ;;
            --help|-h)
                echo "Spider CLI Installer"
                echo ""
                echo "Usage: curl -fsSL https://spiderme.org/install.sh | bash -s -- [options]"
                echo ""
                echo "Options:"
                echo "  --version VERSION    Install specific version (default: latest)"
                echo "  --install-dir PATH   Install directory (default: \$HOME/.local/bin)"
                echo "  --help, -h           Show this help message"
                exit 0
                ;;
            --*)
                error "Unknown option: $1"
                ;;
            *)
                VERSION="$1"
                shift
                ;;
        esac
    done
}

parse_args "$@"

# Detect OS and architecture
detect_platform() {
    local os arch
    
    case "$(uname -s)" in
        Linux*)  os="linux" ;;
        Darwin*) os="macos" ;;
        *)       error "Unsupported operating system: $(uname -s)" ;;
    esac
    
    case "$(uname -m)" in
        x86_64|amd64)  arch="x86_64" ;;
        aarch64|arm64) arch="aarch64" ;;
        *)              error "Unsupported architecture: $(uname -m)" ;;
    esac
    
    echo "${os}-${arch}"
}

# Get latest version from GitHub API
get_latest_version() {
    curl -s "${GITHUB_API}" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/'
}

# Strip leading 'v' from version if present
strip_v_prefix() {
    local ver="$1"
    echo "${ver#v}"
}

# Create install directory
mkdir -p "${INSTALL_DIR}"

# Detect platform
PLATFORM=$(detect_platform)
info "Detected platform: ${PLATFORM}"

# Determine version
if [ "$VERSION" = "latest" ]; then
    info "Fetching latest version..."
    VERSION=$(get_latest_version)
    if [ -z "$VERSION" ]; then
        error "Failed to fetch latest version"
    fi
else
    VERSION="v$(strip_v_prefix "$VERSION")"
fi

info "Installing Spider CLI ${VERSION}..."

# Construct download URL
DOWNLOAD_URL="https://github.com/${SPIDER_REPO}/releases/download/${VERSION}/spider-${PLATFORM}.tar.gz"

# Download and install
info "Downloading from ${DOWNLOAD_URL}..."
TEMP_DIR=$(mktemp -d)
cd "${TEMP_DIR}"

if curl -fsSL "${DOWNLOAD_URL}" -o spider.tar.gz; then
    tar xzf spider.tar.gz
    
    # Find and install the binary
    if [ -f "spider" ]; then
        mv spider "${INSTALL_DIR}/spider"
        chmod +x "${INSTALL_DIR}/spider"
        info "Spider CLI installed to ${INSTALL_DIR}/spider"
    else
        error "Binary not found in archive"
    fi
else
    error "Download failed. Please check if version ${VERSION} exists."
fi

# Cleanup
cd /
rm -rf "${TEMP_DIR}"

# Check PATH
case ":$PATH:" in
    *":${INSTALL_DIR}:"*) ;;
    *)
        warn "Add ${INSTALL_DIR} to your PATH:"
        warn "  export PATH=\"${INSTALL_DIR}:\$PATH\""
        ;;
esac

info "Installation complete! Run 'spider help' to get started."
