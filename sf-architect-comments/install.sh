#!/usr/bin/env bash

DIST_PAGES_URL="https://distribution.usefulto.us/sf-architect-comments"
ZIP_URL="$DIST_PAGES_URL/app.zip"
INSTALL_DIR="$HOME/sf-architect-comments"
GW_URL="https://eng-ai-model-gateway.sfproxy.devx-preprod.aws-esvc1-useast2.aws.sfdc.cl"
GW_TEST_MODEL="gemini-3-flash-preview"
CHECK_ONLY=0
DOWNLOAD_ONLY=0

# ── Argument parsing ──────────────────────────────────────────────────────────
for arg in "$@"; do
  case $arg in
    --check)         CHECK_ONLY=1 ;;
    --download-only) DOWNLOAD_ONLY=1 ;;
    --help|-h)
      echo "Usage: bash install.sh [--check [--download-only]]"
      echo ""
      echo "  (no flags)               Install all missing dependencies and set up the application."
      echo "  --check                  Check whether dependencies are installed without changing anything."
      echo "  --check --download-only  Run checks, then download app.zip to the current directory."
      exit 0
      ;;
  esac
done

if [ $DOWNLOAD_ONLY -eq 1 ] && [ $CHECK_ONLY -eq 0 ]; then
  echo "ERROR: --download-only may only be used with --check."
  echo "Usage: bash install.sh --check --download-only"
  exit 1
fi

# ── Helpers ───────────────────────────────────────────────────────────────────
print_status() {
  local label="$1" ok="$2" detail="$3"
  if [ "$ok" -eq 1 ]; then
    printf "  ✓  %-22s %s\n" "$label" "$detail"
  elif [ "$ok" -eq 2 ]; then
    printf "  ⚠  %-22s %s\n" "$label" "$detail"
  else
    printf "  ✗  %-22s %s\n" "$label" "$detail"
  fi
}

# Download and extract the ZIP into INSTALL_DIR.
# Existing files (like .env, output/) are preserved; app source files are replaced.
download_app() {
  local tmp_dir
  tmp_dir=$(mktemp -d)
  local zip_path="$tmp_dir/app.zip"
  local extracted_name="sf_architect_comments"

  echo "  Checking download URL..."
  local http_status
  http_status=$(curl --max-time 10 --silent --output /dev/null --write-out "%{http_code}" "$ZIP_URL")
  if [ "$http_status" != "200" ]; then
    echo "ERROR: Cannot reach the download URL (HTTP $http_status)."
    echo "       $ZIP_URL"
    echo "       Check your internet connection or try again in a few minutes."
    rm -rf "$tmp_dir"
    return 1
  fi

  echo "  Downloading..."
  curl -fsSL "$ZIP_URL" -o "$zip_path"

  echo "  Extracting..."
  unzip -q "$zip_path" -d "$tmp_dir"

  if [ ! -d "$tmp_dir/$extracted_name" ]; then
    echo "ERROR: Unexpected ZIP structure. Expected '$extracted_name' inside archive."
    rm -rf "$tmp_dir"
    return 1
  fi

  mkdir -p "$INSTALL_DIR"
  # cp -a copies all files from the extracted dir into INSTALL_DIR.
  # Existing files not present in the ZIP (e.g. .env, output/) are untouched.
  cp -a "$tmp_dir/$extracted_name/." "$INSTALL_DIR/"
  rm -rf "$tmp_dir"
}

# Test gateway reachability and optionally validate a key.
# Returns: 0 = reachable+key valid, 1 = reachable+key invalid, 2 = not reachable
test_gateway() {
  local key="$1"
  local curl_opts=(--max-time 8 --silent --output /dev/null --write-out "%{http_code}")
  [ -n "$NODE_EXTRA_CA_CERTS" ] && curl_opts+=(--cacert "$NODE_EXTRA_CA_CERTS")

  if [ -z "$key" ]; then
    local status
    status=$(curl "${curl_opts[@]}" "$GW_URL/models" 2>/dev/null) || true
    [[ "$status" =~ ^[0-9]+$ ]] && [ "$status" -gt 0 ] && return 0
    return 2
  fi

  local body="{\"model\":\"$GW_TEST_MODEL\",\"messages\":[{\"role\":\"user\",\"content\":\"ping\"}],\"max_tokens\":1}"
  local status
  status=$(curl "${curl_opts[@]}" \
    -X POST \
    -H "Authorization: Bearer $key" \
    -H "Content-Type: application/json" \
    -d "$body" \
    "$GW_URL/chat/completions" 2>/dev/null) || true

  [[ "$status" =~ ^[0-9]+$ ]] || return 2
  [ "$status" -eq 200 ] && return 0
  [ "$status" -eq 401 ] && return 1
  [ "$status" -eq 0 ]   && return 2
  return 1
}

# ── Header ────────────────────────────────────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║         Architect Comments — Installer               ║"
echo "╚══════════════════════════════════════════════════════╝"
echo ""
echo "This application requires the following dependencies:"
echo ""
echo "  1. Bun               — the JavaScript runtime that powers the application."
echo "                         Fast and lightweight. https://bun.sh"
echo ""
echo "  2. Homebrew          — the standard macOS package manager, used to install"
echo "                         the Salesforce CLI. https://brew.sh"
echo ""
echo "  3. Salesforce CLI    — Salesforce's official command-line tool. The app"
echo "                         uses it to query org62 for Opportunity records."
echo "                         You must be logged in to org62 (your internal"
echo "                         Salesforce production org). Credentials are managed"
echo "                         by Salesforce, never by this application."
echo "                         https://developer.salesforce.com/tools/salesforcecli"
echo ""
echo "  4. Gateway API key   — your personal key for the Engineering AI Model"
echo "                         Gateway, which runs the LLM generation step."
echo "                         The installer will test that the key works before"
echo "                         saving it. You can also configure this later in"
echo "                         the application's Settings page."
echo ""
echo "────────────────────────────────────────────────────────"
echo "Checking your system..."
echo ""

# ── Dependency check ──────────────────────────────────────────────────────────
BUN_OK=0; BREW_OK=0; CURL_OK=0; UNZIP_OK=0; SF_OK=0; ORG62_OK=0; APP_INSTALLED=0
GW_REACHABLE=0; GW_KEY_OK=0; GW_KEY_CONFIGURED=0; ZIP_OK=0

command -v bun   >/dev/null 2>&1 && BUN_OK=1
command -v brew  >/dev/null 2>&1 && BREW_OK=1
command -v curl  >/dev/null 2>&1 && CURL_OK=1
command -v unzip >/dev/null 2>&1 && UNZIP_OK=1
command -v sf    >/dev/null 2>&1 && SF_OK=1

ZIP_HTTP=$(curl --max-time 10 --silent --output /dev/null --write-out "%{http_code}" "$ZIP_URL" 2>/dev/null)
[ "$ZIP_HTTP" = "200" ] && ZIP_OK=1
# App is considered installed if the server entry point is present
[ -f "$INSTALL_DIR/src/web-server.js" ] && APP_INSTALLED=1
APP_VERSION="unknown"
[ -f "$INSTALL_DIR/VERSION" ] && APP_VERSION=$(cat "$INSTALL_DIR/VERSION")

# Check if org62 is authenticated
if [ $SF_OK -eq 1 ]; then
  sf org display --target-org org62 --json >/dev/null 2>&1 && ORG62_OK=1
fi

# Check for an existing saved key (from .env or current environment)
SAVED_KEY=""
INPUT_KEY=""
ENV_FILE="$INSTALL_DIR/.env"
if [ -f "$ENV_FILE" ]; then
  SAVED_KEY=$(grep '^ENG_AI_MODEL_GW_KEY=' "$ENV_FILE" 2>/dev/null | cut -d= -f2- | tr -d '"'"'" | head -1)
fi
[ -z "$SAVED_KEY" ] && [ -n "$ENG_AI_MODEL_GW_KEY" ] && SAVED_KEY="$ENG_AI_MODEL_GW_KEY"
[ -n "$SAVED_KEY" ] && GW_KEY_CONFIGURED=1

# Gateway reachability
echo "  Checking gateway connectivity..."
test_gateway "" && GW_REACHABLE=1 || true
echo ""

# ── API key prompt ────────────────────────────────────────────────────────────
if [ $GW_REACHABLE -eq 1 ]; then
  echo "────────────────────────────────────────────────────────"
  echo "Engineering AI Gateway — API key"
  echo ""
  echo "The gateway is reachable. Enter your personal API key to verify it works."
  echo "If you do not have a key yet, press Enter to skip and configure it later"
  echo "in the application's Settings page."
  echo ""

  KEY_ATTEMPTS=0
  while [ $GW_KEY_OK -eq 0 ] && [ $KEY_ATTEMPTS -lt 3 ]; do
    KEY_ATTEMPTS=$(( KEY_ATTEMPTS + 1 ))

    if [ $GW_KEY_CONFIGURED -eq 1 ] && [ $KEY_ATTEMPTS -eq 1 ]; then
      echo "  A key is already saved. Press Enter to test it, or type a new one."
    fi

    read -s -r -p "  API key (input hidden): " INPUT_KEY
    echo ""

    # Blank input + saved key → test the saved key
    if [ -z "$INPUT_KEY" ] && [ $GW_KEY_CONFIGURED -eq 1 ]; then
      INPUT_KEY="$SAVED_KEY"
    fi

    if [ -z "$INPUT_KEY" ]; then
      echo "  Skipped. You can enter your key later in the app's Settings page."
      echo ""
      break
    fi

    echo ""
    echo "  Testing key with model '$GW_TEST_MODEL' ..."
    set +e; test_gateway "$INPUT_KEY"; KEY_TEST_RESULT=$?; set -e

    if [ $KEY_TEST_RESULT -eq 0 ]; then
      GW_KEY_OK=1; GW_KEY_CONFIGURED=1
      echo "  ✓ Key is valid."
      echo ""
    elif [ $KEY_TEST_RESULT -eq 1 ]; then
      echo "  ✗ The key was rejected (HTTP 401). Check you copied the full key without extra spaces."
      INPUT_KEY=""
      if [ $KEY_ATTEMPTS -lt 3 ]; then
        echo "    Please try again."
        echo ""
      else
        echo "    Could not validate the key after 3 attempts. Skipping."
        echo "    Configure it later in the app's Settings page."
        echo ""
      fi
    else
      echo "  ✗ The gateway did not respond during the test. Skipping."
      echo "    You can configure the key later in the app's Settings page."
      INPUT_KEY=""
      break
    fi
  done
  echo "────────────────────────────────────────────────────────"
  echo ""
fi

# ── Status table ──────────────────────────────────────────────────────────────
echo "Summary"
echo ""
print_status "Bun"            "$BUN_OK"          "$(bun --version 2>/dev/null)"
print_status "Homebrew"       "$BREW_OK"         "$(brew --version 2>/dev/null | head -1)"
print_status "curl"           "$CURL_OK"         "$(curl --version 2>/dev/null | head -1)"
print_status "unzip"          "$UNZIP_OK"        "$(unzip -v 2>/dev/null | head -1)"
print_status "Salesforce CLI" "$SF_OK"           "$(sf --version 2>/dev/null | head -1)"
if [ $SF_OK -eq 1 ]; then
  if [ $ORG62_OK -eq 1 ]; then
    ORG62_USER=$(sf org display --target-org org62 --json 2>/dev/null \
      | grep '"username"' | head -1 \
      | sed 's/.*"username": *"\([^"]*\)".*/\1/')
    print_status "org62 login"  1 "logged in as $ORG62_USER"
  else
    print_status "org62 login"  0 "not authenticated"
  fi
fi
print_status "Application"    "$APP_INSTALLED"   "$([ $APP_INSTALLED -eq 1 ] && echo "installed at $INSTALL_DIR" || echo "not yet installed")"
if [ $APP_INSTALLED -eq 1 ]; then
  print_status "Version"      1                  "$APP_VERSION"
fi
print_status "Download URL"   "$ZIP_OK"          "$([ $ZIP_OK -eq 1 ] && echo "$ZIP_URL" || echo "not reachable (HTTP $ZIP_HTTP) — check VPN or try again later")"
echo ""

if [ $GW_REACHABLE -eq 0 ]; then
  print_status "Gateway" 0 "not reachable — check VPN"
  print_status "API key" 0 "cannot test (gateway unreachable)"
elif [ $GW_KEY_OK -eq 1 ]; then
  print_status "Gateway" 1 "reachable"
  print_status "API key" 1 "verified and working"
elif [ $GW_KEY_CONFIGURED -eq 1 ]; then
  print_status "Gateway" 1 "reachable"
  print_status "API key" 2 "saved but could not be verified"
else
  print_status "Gateway" 1 "reachable"
  print_status "API key" 0 "not configured"
fi

echo ""

# ── Check-only mode: exit here ────────────────────────────────────────────────
if [ $CHECK_ONLY -eq 1 ]; then
  ALL_OK=$(( BUN_OK && BREW_OK && CURL_OK && UNZIP_OK && SF_OK && ORG62_OK && APP_INSTALLED && ZIP_OK ))
  if [ $ALL_OK -eq 1 ] && [ $GW_KEY_OK -eq 1 ]; then
    echo "Everything is installed and configured. Run 'sfac' to launch the app."
  elif [ $ALL_OK -eq 1 ]; then
    echo "Dependencies are installed but the API key needs attention."
    echo "Run 'bash install.sh' to configure it, or open Settings in the app."
  else
    echo "Some items need attention. Run 'bash install.sh' to resolve them."
  fi
  echo ""

  if [ $DOWNLOAD_ONLY -eq 1 ]; then
    if [ $ZIP_OK -eq 0 ]; then
      echo "Cannot download: app.zip is not reachable (HTTP $ZIP_HTTP)."
      echo ""
      exit 1
    fi
    DEST="$(pwd)/app.zip"
    echo "Downloading app.zip to $DEST ..."
    curl -fsSL "$ZIP_URL" -o "$DEST"
    echo "Done."
    echo ""
  fi

  exit 0
fi

# ── Determine what needs to be installed ─────────────────────────────────────
NEEDS_INSTALL=()
[ $BUN_OK        -eq 0 ] && NEEDS_INSTALL+=("Bun")
[ $BREW_OK       -eq 0 ] && NEEDS_INSTALL+=("Homebrew")
[ $CURL_OK       -eq 0 ] && NEEDS_INSTALL+=("curl")
[ $UNZIP_OK      -eq 0 ] && NEEDS_INSTALL+=("unzip")
[ $SF_OK         -eq 0 ] && NEEDS_INSTALL+=("Salesforce CLI")
[ $APP_INSTALLED -eq 0 ] && NEEDS_INSTALL+=("Architect Comments")

if [ ${#NEEDS_INSTALL[@]} -eq 0 ]; then
  echo "All software dependencies are installed."
  echo ""
  read -r -p "Download and apply the latest update? [Y/n] " DO_UPDATE
  DO_UPDATE="${DO_UPDATE:-Y}"
  if [[ "$DO_UPDATE" =~ ^[Yy]$ ]]; then
    echo ""
    download_app
    cd "$INSTALL_DIR" && bun install --silent
    echo "✓ Updated to latest version."
  else
    echo "Skipped."
  fi
  echo ""
  echo "Run 'sfac' to launch the app."
  echo ""
  exit 0
fi

echo "The following will be installed:"
echo ""
for item in "${NEEDS_INSTALL[@]}"; do
  echo "    • $item"
done
echo ""
echo "No other changes will be made to your system."
echo ""

# ── Confirm ───────────────────────────────────────────────────────────────────
read -r -p "Continue? [Y/n] " CONFIRM
CONFIRM="${CONFIRM:-Y}"
if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
  echo ""
  echo "Installation cancelled. Nothing was changed."
  echo ""
  exit 0
fi
echo ""

set -e

# ── 1. Bun ───────────────────────────────────────────────────────────────────
if [ $BUN_OK -eq 0 ]; then
  echo "Installing Bun..."
  curl -fsSL https://bun.sh/install | bash
  export BUN_INSTALL="$HOME/.bun"
  export PATH="$BUN_INSTALL/bin:$PATH"
  echo "✓ Bun $(bun --version)"
  echo ""
fi

# ── 2. Homebrew ──────────────────────────────────────────────────────────────
if [ $BREW_OK -eq 0 ]; then
  echo "Installing Homebrew..."
  echo "(You may be prompted for your macOS login password — this is expected.)"
  echo ""
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  [ -f /opt/homebrew/bin/brew ] && eval "$(/opt/homebrew/bin/brew shellenv)"
  [ -f /usr/local/bin/brew ]    && eval "$(/usr/local/bin/brew shellenv)"
  echo "✓ Homebrew $(brew --version | head -1)"
  echo ""
fi

# ── 3. curl and unzip ────────────────────────────────────────────────────────
if [ $CURL_OK -eq 0 ]; then
  echo "Installing curl..."
  brew install curl
  echo "✓ curl $(curl --version 2>/dev/null | head -1)"
  echo ""
fi

if [ $UNZIP_OK -eq 0 ]; then
  echo "Installing unzip..."
  brew install unzip
  echo "✓ unzip $(unzip -v 2>/dev/null | head -1)"
  echo ""
fi

# ── 4. Salesforce CLI ────────────────────────────────────────────────────────
if [ $SF_OK -eq 0 ]; then
  echo "Installing Salesforce CLI..."
  brew install sf
  echo "✓ Salesforce CLI $(sf --version 2>/dev/null | head -1)"
  echo ""
fi

# ── 5. Download application ───────────────────────────────────────────────────
echo "Downloading Architect Comments..."
download_app
cd "$INSTALL_DIR"
bun install --silent
APP_VERSION=$(cat "$INSTALL_DIR/VERSION" 2>/dev/null || echo "unknown")
echo "✓ Application ready (version $APP_VERSION)"
echo ""

# ── 6. Create .env ────────────────────────────────────────────────────────────
ENV_FILE="$INSTALL_DIR/.env"
ENV_WRITTEN=0

ENV_LINES="# Architect Comments — generated by installer on $(date '+%Y-%m-%d')"
ENV_LINES="$ENV_LINES
# Do not commit this file; it may contain your API key."
ENV_LINES="$ENV_LINES

ENG_AI_MODEL_GW_URL=$GW_URL"

if [ $GW_KEY_OK -eq 1 ] && [ -n "$INPUT_KEY" ]; then
  ENV_LINES="$ENV_LINES
ENG_AI_MODEL_GW_KEY=$INPUT_KEY"
fi

ENV_LINES="$ENV_LINES
ENG_AI_MODEL=$GW_TEST_MODEL
LLM_CACHE=true"

if [ $ORG62_OK -eq 1 ]; then
  ENV_LINES="$ENV_LINES
SF_TARGET_ORG=org62"
fi

echo "────────────────────────────────────────────────────────"
echo "Create configuration file"
echo ""
echo "The installer will write the following to:"
echo "  $ENV_FILE"
echo ""

while IFS= read -r line; do
  if [[ "$line" =~ ^ENG_AI_MODEL_GW_KEY= ]]; then
    KEY_VAL="${line#ENG_AI_MODEL_GW_KEY=}"
    KEY_LEN=${#KEY_VAL}
    if [ $KEY_LEN -gt 8 ]; then
      MASKED="${KEY_VAL:0:4}$(printf '%0.s•' $(seq 1 $(( KEY_LEN - 8 ))))${KEY_VAL: -4}"
    else
      MASKED="$(printf '%0.s•' $(seq 1 $KEY_LEN))"
    fi
    echo "    ENG_AI_MODEL_GW_KEY=$MASKED"
  else
    echo "    $line"
  fi
done <<< "$ENV_LINES"

echo ""
[ -f "$ENV_FILE" ] && echo "  A .env file already exists at this location and will be overwritten." && echo ""

read -r -p "Write this file? [Y/n] " WRITE_CONFIRM
WRITE_CONFIRM="${WRITE_CONFIRM:-Y}"
if [[ "$WRITE_CONFIRM" =~ ^[Yy]$ ]]; then
  printf '%s\n' "$ENV_LINES" > "$ENV_FILE"
  ENV_WRITTEN=1
  echo "✓ Configuration saved to $ENV_FILE"
else
  echo "Skipped. No file was written."
  echo "You can configure the application manually or through the Settings page."
fi
echo "────────────────────────────────────────────────────────"
echo ""

[ $GW_REACHABLE -eq 0 ] && [ $ENV_WRITTEN -eq 0 ] && {
  echo "Note: the gateway was not reachable during installation."
  echo "Connect to Salesforce VPN and re-run the installer, or configure"
  echo "your API key in the application's Settings page after launching."
  echo ""
}

# ── 7. org62 authentication check ────────────────────────────────────────────
# Re-check in case SF CLI was just installed
[ $ORG62_OK -eq 0 ] && command -v sf >/dev/null 2>&1 && \
  sf org display --target-org org62 --json >/dev/null 2>&1 && ORG62_OK=1 || true

if [ $ORG62_OK -eq 0 ]; then
  echo "────────────────────────────────────────────────────────"
  echo "Log in to org62."
  echo ""
  echo "org62 is your internal Salesforce production org — the org this application"
  echo "queries to retrieve Opportunity records. You need to authenticate once."
  echo "Your credentials are stored securely by the Salesforce CLI and are never"
  echo "accessed or stored by this application."
  echo ""
  echo "Run the following command. A browser window will open for you to log in:"
  echo ""
  echo "    sf org login web --instance-url https://org62.my.salesforce.com --alias org62"
  echo ""
  echo "Once logged in, run 'sfac' to launch the application."
  echo "────────────────────────────────────────────────────────"
  echo ""
else
  ORG62_USER=$(sf org display --target-org org62 --json 2>/dev/null \
    | grep '"username"' | head -1 \
    | sed 's/.*"username": *"\([^"]*\)".*/\1/')
  echo "✓ Logged in to org62 as $ORG62_USER"
  echo ""
fi

# ── 8. Shell alias ────────────────────────────────────────────────────────────
ALIAS_LINE="alias sfac=\"bash \$HOME/sf-architect-comments/start.sh\""
ADDED=0
for RC in "$HOME/.zshrc" "$HOME/.bashrc"; do
  if [ -f "$RC" ] && ! grep -qF 'sfac' "$RC"; then
    echo "$ALIAS_LINE" >> "$RC"
    ADDED=1
  fi
done
[ $ADDED -eq 1 ] && echo "✓ Added 'sfac' shortcut to your shell config"

echo ""
echo "Installation complete."
echo ""
echo "Open a new terminal tab and run:  sfac"
echo ""
echo "The app will open at http://localhost:3000."
echo ""
