#!/usr/bin/env bash
# Phase 1 - is every expected tool present, and at the version REA admits?
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$DIR/lib.sh"

section "runtime"
check "node version"        "v(22|24|26)\."           -- node --version
check "npm present"         "."                        -- npm --version
check "rea version"         "."                        -- rea --version
if engine_has ida && [ -z "${REA_IDA_MCP_CONFIG:-}" ]; then
    check "rea providers (no bundled engine)" "." -- rea providers --json
else
    check "rea providers"       "ghidra|hopper"            -- rea providers --json
fi

section "engine profile"
check "declared engine"      "." -- cat /usr/local/share/rea/engine
# The ida image legitimately has no engine paths at all, so this asserts the file
# exists and reports how much it declares rather than requiring content.
check "engine env file"      "engine.env present" \
    -- bash -c 'test -f /usr/local/share/rea/engine.env && echo "engine.env present ($(grep -c "^export " /usr/local/share/rea/engine.env || true) exports)"'
check "rea wrapper injects engine env" "^/opt/(ghidra|hopper)|^/opt/ida$" \
    -- bash -c '[ -r /usr/local/share/rea/engine.env ] && . /usr/local/share/rea/engine.env && case "$(cat /usr/local/share/rea/engine)" in all|ghidra) echo "$GHIDRA_INSTALL_DIR" ;; all|hopper) echo "$HOPPER_LAUNCHER_PATH" ;; ida) echo "${IDADIR:-/opt/ida}" ;; esac'
check "rea wrapper is the engine-injecting shell script" "engine.env" \
    -- bash -c 'head -6 /usr/local/bin/rea; test -x /usr/local/bin/rea-npm-shim && echo "npm shim present"'

section "container healthcheck"
# The same script Docker runs as HEALTHCHECK: it must call THIS image healthy, and
# must not demand an engine the image does not carry.
check "healthcheck reports healthy" "^healthy:" -- /usr/local/bin/rea-agent-healthcheck
if [ "$(image_engine)" = "ida" ] && [ -z "${REA_IDA_MCP_CONFIG:-}" ]; then
    # Correct behaviour, asserted positively: with no engine and no registration,
    # the *deep* healthcheck says exactly that instead of claiming health.
    check "healthcheck (deep) names the missing IDA registration" \
        "REA_IDA_MCP_CONFIG is not set" \
        -- bash -c 'REA_HEALTHCHECK_DEEP=1 /usr/local/bin/rea-agent-healthcheck 2>&1; true'
else
    check "healthcheck (deep) reports healthy" "^healthy:" \
        -- bash -c 'REA_HEALTHCHECK_DEEP=1 /usr/local/bin/rea-agent-healthcheck'
fi

section "analysis engines"
check "java runtime"        "openjdk|java"             -- bash -c "java -version 2>&1 | head -1"
check "javac present"       "."                        -- bash -c "javac -version 2>&1"
if engine_has ghidra; then
    check "ghidra analyzeHeadless executable" "analyzeHeadless" -- bash -c "ls -l \"$GHIDRA_INSTALL_DIR/support/analyzeHeadless\""
    check "ghidra native decompiler (linux_x86_64)" "linux_x86_64" -- bash -c "find \"$GHIDRA_INSTALL_DIR/Ghidra/Features/Decompiler/os\" -name decompile -type f | head -5"
else
    _skip "ghidra installation" "not in this image (engine: $(image_engine))"
fi
if engine_has hopper; then
    check "hopper launcher executable" "Hopper"            -- bash -c "ls -l \"$HOPPER_LAUNCHER_PATH\""
    check "hopper shared libraries resolve (0 = none missing)" "^0$" \
        -- bash -c "ldd \"$HOPPER_LAUNCHER_PATH\" | grep -c 'not found' || true"
    check "hopper launcher digest is one REA accepts" "0294ced1|1339f9e5" \
        -- bash -c "sha256sum \"$HOPPER_LAUNCHER_PATH\""
    check "xvfb present"        "/usr/bin/Xvfb"            -- which Xvfb
else
    _skip "hopper installation" "not in this image (engine: $(image_engine))"
fi
if engine_has ida; then
    check "IDA mount point" "." -- bash -c "ls -ld \"${IDADIR:-/opt/ida}\""
    check "IDA licence placement helpers" "." -- bash -c "ls -l /opt/rea/scripts/setup-ida-mcp.sh"
fi

section "static analysis helpers"
check "pwntools venv python"  "pwntools"               -- bash -c "$REA_PWNTOOLS_PYTHON -c 'import pwn, elftools, unicorn; print(\"pwntools\", pwn.version, \"pyelftools\", elftools.__version__, \"unicorn\", unicorn.__version__)'"
check "wabt 1.0.42"           "1\.0\.42"               -- bash -c "$REA_WABT_BIN_DIRECTORY/wasm2wat --version"
check "jadx headless MCP jar" "\.jar$"                 -- bash -c "ls -l \"$REA_JADX_MCP_JAR\""
check "jadx jar is a runnable archive" "Main-Class"    -- bash -c "unzip -p \"$REA_JADX_MCP_JAR\" META-INF/MANIFEST.MF | tr -d '\r' | grep -i 'Main-Class'"
check "apktool launcher"      "2\.[0-9]+"              -- apktool --version
check "dotnet sdk"            "8\."                    -- dotnet --version
check "ilspycmd"              "ILSpy|[0-9]+\.[0-9]+"   -- "$REA_ILSPY_CMD_PATH" --version

section "firmware / packet / signal"
check "binwalk"               "Binwalk|binwalk|3\."    -- binwalk --version
check "unblob"                "26\.6"                  -- "$REA_UNBLOB_COMMAND" --version
check "tshark"                "TShark|4\."             -- tshark --version
check "capinfos"              "."                      -- capinfos --version
check "sigrok-cli"            "0\.7\.2"                -- sigrok-cli --version
check "sigrok backend loads libsigrokdecode" "libsigrokdecode" -- bash -c "sigrok-cli --version 2>&1 | grep -i libsigrokdecode"

section "capture / devices"
check "mitmdump"              "12\.2\.3"               -- "$REA_MITMDUMP_COMMAND" --version
check "adb"                   "Android Debug Bridge|1\." -- adb version
check "frida binding loads and sees the local device" "frida" -- bash -c "cd \"\$(npm root -g)/rea-agents\" && node -e 'const f=require(\"frida\");f.getLocalDevice().then(d=>console.log(\"frida local device:\",d.name))'"

section "debuggers and arch emulation"
check "gdb"                   "GNU gdb"                -- gdb --version
check "gdb-multiarch"         "GNU gdb"                -- gdb-multiarch --version
check "gdb sources pwndbg"    "pwndbg"                 -- bash -c "PWNDBG_NO_AUTOUPDATE=1 gdb --batch -q -nx -ex 'source /opt/pwndbg/gdbinit.py' -ex 'pi print(\"pwndbg-loaded\")' 2>&1 | tail -3"
check "qemu-user-static"      "qemu"                   -- bash -c "qemu-aarch64-static --version | head -1"
check "wine"                  "wine|not found"         -- bash -c "wine --version 2>&1 | head -1 || true"

section "browsers"
check "google-chrome"         "Google Chrome"           -- google-chrome --version
check "playwright chromium"   "chromium|chrome"         -- bash -c "find /opt/ms-playwright -maxdepth 3 -name 'chrome' -o -maxdepth 3 -name 'headless_shell' | head -5"
