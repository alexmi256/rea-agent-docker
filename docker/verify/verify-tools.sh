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
check "rea providers"       "ghidra|hopper"            -- rea providers --json

section "analysis engines"
check "ghidra analyzeHeadless executable" "analyzeHeadless" -- bash -c "ls -l \"$GHIDRA_INSTALL_DIR/support/analyzeHeadless\""
check "ghidra native decompiler (linux_x86_64)" "linux_x86_64" -- bash -c "find \"$GHIDRA_INSTALL_DIR/Ghidra/Features/Decompiler/os\" -name decompile -type f | head -5"
check "java runtime"        "openjdk|java"             -- java -version
check "javac present"       "."                        -- javac -version
check "hopper launcher executable" "Hopper"            -- bash -c "ls -l \"$HOPPER_LAUNCHER_PATH\""
check "hopper shared libraries resolve" "not found|^$" -- bash -c "ldd \"$HOPPER_LAUNCHER_PATH\" | grep 'not found' || true"
check "xvfb present"        "/usr/bin/Xvfb"            -- which Xvfb

section "static analysis helpers"
check "pwntools venv python"  "pwntools"               -- bash -c "$REA_PWNTOOLS_PYTHON -c 'import pwn,elftools,unicorn;from pwn import version;print(\"pwntools\",version.version)'"
check "wabt 1.0.42"           "1\.0\.42"               -- bash -c "$REA_WABT_BIN_DIRECTORY/wasm2wat --version"
check "jadx headless MCP jar" "\.jar$"                 -- bash -c "ls -l \"$REA_JADX_MCP_JAR\""
check "jadx jar contains engine classes" "jadx"        -- bash -c "unzip -l \"$REA_JADX_MCP_JAR\" | grep -m1 -i 'jadx'"
check "apktool launcher"      "2\.[0-9]+"              -- apktool --version
check "dotnet sdk"            "8\."                    -- dotnet --version
check "ilspycmd"              "ILSpy|ilspycmd|[0-9]"   -- bash -c "ilspycmd --version || $REA_ILSPY_CMD_PATH --version"

section "firmware / packet / signal"
check "binwalk"               "Binwalk|binwalk|3\."    -- binwalk --version
check "unblob"                "26\.6"                  -- "$REA_UNBLOB_COMMAND" --version
check "tshark"                "TShark|4\."             -- tshark --version
check "capinfos"              "."                      -- capinfos --version
check "sigrok-cli"            "0\.7\.2"                -- sigrok-cli --version
check "libsigrokdecode decoders" "."                   -- bash -c "sigrok-cli --list-decoders | head -20"

section "capture / devices"
check "mitmdump"              "12\.2\.3"               -- "$REA_MITMDUMP_COMMAND" --version
check "adb"                   "Android Debug Bridge|1\." -- adb version
check "frida (npm binding)"   "[0-9]+\.[0-9]+"         -- bash -c "node -e \"const f=require('/usr/lib/node_modules/rea-agents/node_modules/frida');console.log(f.version)\""

section "debuggers and arch emulation"
check "gdb"                   "GNU gdb"                -- gdb --version
check "gdb-multiarch"         "GNU gdb"                -- gdb-multiarch --version
check "gdb loads pwndbg"      "pwndbg"                 -- bash -c "PWNDBG_NO_AUTOUPDATE=1 gdb --batch -nx -ex 'pi import pwndbg; print(\"pwndbg\", pwndbg.version.commit[:8])' 2>&1 | tail -2"
check "qemu-user-static"      "qemu"                   -- bash -c "qemu-aarch64-static --version | head -1"
check "wine"                  "wine|not found"         -- bash -c "wine --version 2>&1 | head -1 || true"

section "browsers"
check "google-chrome"         "Google Chrome"           -- google-chrome --version
check "playwright chromium"   "chromium|chrome"         -- bash -c "find /opt/ms-playwright -maxdepth 3 -name 'chrome' -o -maxdepth 3 -name 'headless_shell' | head -5"
