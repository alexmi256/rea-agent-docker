# Third-party notices

This repository is MIT-licensed (see [`LICENSE`](../LICENSE)) and covers the
files here: the Dockerfile, compose files, scripts and documentation.

The **image it builds** installs a lot of third-party software, each of which
keeps its own licence and terms. That installed set is:

| Component | Licence |
| --- | --- |
| Ghidra | Apache-2.0 |
| OpenJDK 21 | GPL-2.0-with-classpath-exception |
| Node.js | MIT |
| REA (`rea-agents`) | MIT |
| Qt6 runtime (Hopper's dependency) | LGPL-3.0 |
| Hopper (Linux demo package) | commercial; the **public demo** build is redistributed here exactly as downloaded from the vendor |
| WABT | Apache-2.0 |
| Wakaru | Apache-2.0 |
| Apktool | Apache-2.0 |
| jadx-headless-mcp | Apache-2.0 |
| .NET SDK 8 | MIT |
| ILSpy / `ilspycmd` | MIT |
| pwntools | MIT |
| pyelftools | public domain |
| Unicorn | GPL-2.0 |
| pwndbg | MIT |
| unblob | MIT |
| mitmproxy | MIT |
| Wireshark / `tshark` and `capinfos` | GPL-2.0 |
| sigrok-cli / libsigrokdecode | GPL-3.0 |
| Android platform-tools (`adb`) | Apache-2.0 |
| binwalk | MIT |
| wine | LGPL-2.1 |
| Frida | wxWindows Library Licence (LGPL-2.1-based) |
| supergateway | MIT |
| uv | Apache-2.0 / MIT |
| Google Chrome (stable) | proprietary; packaged `.deb` redistributed as downloaded from Google |
| e2fsprogs, dosfstools, mtools, device-tree-compiler, squashfs-tools, cpio, sleuthkit, 7-Zip, cabextract, yara, upx, nasm, qemu-user-static, cross toolchains, X11/Qt/font libraries | the licence of each Debian/Ubuntu package (predominantly GPL/LGPL/BSD/MIT — see `/usr/share/doc/<package>/copyright` inside the image) |

## Not included, on purpose

**IDA Pro / IDA Home / IDA Free** and **JEB** are *not* included in any image
this project builds. They must be obtained and licensed separately by the
operator, and redistributing them is not permitted by their licences — keep any
image that contains your own IDA or JEB install private. See
[`BYO-LICENSES.md`](BYO-LICENSES.md) and [`ida-variants.md`](ida-variants.md).

A **licensed Hopper** package is likewise yours to supply: the repo only ever
downloads the vendor's public demo build, and a licensed `.deb` you drop into
`vendor/` (never committed — see `.gitignore`) is your responsibility to keep
private.
