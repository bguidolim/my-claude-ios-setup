# ---------------------------------------------------------------------------
# Utility Functions
# ---------------------------------------------------------------------------

info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
success() { echo -e "${GREEN}[OK]${NC} $1"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
error()   { echo -e "${RED}[ERROR]${NC} $1"; }

header() {
    echo ""
    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BOLD}  $1${NC}"
    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

step() {
    local current=$1
    local total=$2
    local msg=$3
    echo ""
    echo -e "${BOLD}[${current}/${total}] ${msg}${NC}"
    echo -e "${DIM}──────────────────────────────────────────${NC}"
}

ask_yn() {
    local prompt=$1
    local default=${2:-Y}
    local yn_hint
    if [[ "$default" == "Y" ]]; then
        yn_hint="[Y/n]"
    else
        yn_hint="[y/N]"
    fi
    while true; do
        echo -ne "  ${prompt} ${yn_hint}: "
        local answer
        read -r answer
        answer=${answer:-$default}
        case "$answer" in
            [yY]|[yY][eE][sS]) return 0 ;;
            [nN]|[nN][oO])     return 1 ;;
            *)                  echo "  Please answer y or n." ;;
        esac
    done
}

check_command() {
    command -v "$1" >/dev/null 2>&1
}

# Run a command, capturing stderr. On failure, warn instead of crashing.
# Usage: try_install "Label" command args...
try_install() {
    local label=$1
    shift
    local err_output
    if err_output=$("$@" 2>&1); then
        INSTALLED_ITEMS+=("$label")
        return 0
    else
        warn "Failed to install $label"
        [[ -n "$err_output" ]] && echo -e "  ${DIM}${err_output}${NC}" | head -3
        SKIPPED_ITEMS+=("$label (failed)")
        return 1
    fi
}

# Escape a string for use in sed replacement (handles /, &, \)
sed_escape() {
    printf '%s' "$1" | sed 's/[&/\\]/\\&/g'
}

backup_file() {
    local file=$1
    if [[ -f "$file" ]]; then
        local backup="${file}.${BACKUP_SUFFIX}"
        cp "$file" "$backup"
        CREATED_BACKUPS+=("$backup")
        info "Backed up $(basename "$file") → $(basename "$backup")"
    fi
}

# Hash a file for manifest tracking (sha256, macOS compatible)
file_hash() {
    shasum -a 256 "$1" 2>/dev/null | cut -d' ' -f1
}

# Record a source→installed mapping in the manifest
# Usage: manifest_record "relative/source/path"
manifest_record() {
    local rel_path=$1
    local hash
    hash=$(file_hash "$SCRIPT_DIR/$rel_path")
    # Remove old entry if present, then append
    if [[ -f "$SETUP_MANIFEST" ]]; then
        grep -v "^${rel_path}=" "$SETUP_MANIFEST" > "${SETUP_MANIFEST}.tmp" 2>/dev/null || true
        mv "${SETUP_MANIFEST}.tmp" "$SETUP_MANIFEST"
    fi
    echo "${rel_path}=${hash}" >> "$SETUP_MANIFEST"
}

# Initialize manifest with SCRIPT_DIR header
manifest_init() {
    mkdir -p "$(dirname "$SETUP_MANIFEST")"
    echo "SCRIPT_DIR=${SCRIPT_DIR}" > "$SETUP_MANIFEST"
}

detect_brew_path() {
    if [[ "$(uname -m)" == "arm64" ]]; then
        echo "/opt/homebrew/bin/brew"
    else
        echo "/usr/local/bin/brew"
    fi
}

ensure_brew_in_path() {
    if ! check_command brew; then
        local brew_path
        brew_path=$(detect_brew_path)
        if [[ -f "$brew_path" ]]; then
            eval "$("$brew_path" shellenv)"
        fi
    fi
}

# Read an env var from an existing MCP server in ~/.claude.json
# Usage: get_mcp_env "server-name" "ENV_VAR_NAME"
# Returns the value on stdout, or empty string if not found
get_mcp_env() {
    local server=$1
    local var_name=$2
    if [[ -f "$CLAUDE_JSON" ]]; then
        if check_command jq; then
            jq -r ".mcpServers.\"${server}\".env.\"${var_name}\" // empty" "$CLAUDE_JSON" 2>/dev/null || true
        else
            # Fallback: rough grep extraction (works for simple string values)
            grep -o "\"${var_name}\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" "$CLAUDE_JSON" 2>/dev/null \
                | head -1 | sed 's/.*:.*"\(.*\)"/\1/' || true
        fi
    fi
}

# Run claude CLI without nesting check
claude_cli() {
    CLAUDECODE="" claude "$@"
}

# Add (or replace) an MCP server. Removes existing entry first to avoid
# "already exists" errors, and places the server name before -e flags
# so the variadic --env doesn't consume the name.
# Usage: mcp_add <name> [options...] [-- command args...]
mcp_add() {
    local name=$1
    shift
    claude_cli mcp remove -s user "$name" 2>/dev/null || true
    claude_cli mcp add -s user "$name" "$@"
}

# Check if Ollama service is running and the embedding model is available
ollama_fully_ready() {
    check_command ollama || return 1
    local tags
    tags=$(curl -s --max-time 3 http://localhost:11434/api/tags 2>/dev/null) || return 1
    echo "$tags" | grep -q "nomic-embed-text"
}
