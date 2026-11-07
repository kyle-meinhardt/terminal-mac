# Third-party notices

The original terminal-mac sources retain their [MIT license](LICENSE) and copyright notices.

## LibVNCClient / LibVNCServer

The session backend uses [LibVNCClient](https://github.com/LibVNC/libvncserver), built from pinned upstream source with the virtual-session handshake patch in `patches/libvncclient-virtual-session.patch`. The build script records and verifies the source revision and checksum. The library is **GNU General Public License version 2 or later (GPL-2.0-or-later)**, not LGPL. A copy of the GPL version 2 is included at [licenses/GPL-2.0.txt](licenses/GPL-2.0.txt).

The upstream [licensing notice and FAQ](https://github.com/LibVNC/libvncserver#license) state that a program linking to LibVNCClient is a derivative work. This fork selects GPL version 3 or later for the combined session-enabled program (per the library's “or later” permission), while the original MIT notices remain applicable to those source files. Loading the library dynamically does not remove its license obligations.

This fork's session integration additions are available under GPL-2.0-or-later. They are supplied without warranty. If distributing the combined executable, also provide the applicable license notices and complete corresponding source (including the matching library/dependency sources and build instructions), as required by the GPL. A source checkout with a development build against a user-installed Homebrew library is not a self-contained binary distribution.

The session library and OpenSSL runtime files are produced in `.build/session-libs`. Development execution loads them from there; packaged builds must carry these optional libraries and the notices beside the executable. Original upstream release packaging instructions alone are insufficient for redistribution of the session-enabled combined program.

A copy of GPL version 3 is included at [licenses/GPL-3.0.txt](licenses/GPL-3.0.txt). GPL version 3 is selected for the combined program because the bundled OpenSSL dependency uses Apache License 2.0; see the [Apache Software Foundation compatibility statement](https://www.apache.org/licenses/GPL-compatibility).

## OpenSSL

The session build links to and copies the installed Homebrew OpenSSL runtime (currently `openssl@4`) and rewrites the library paths to be relative to the session library. OpenSSL is licensed under the Apache License, Version 2.0. The full notice is included at [licenses/OpenSSL-Apache-2.0.txt](licenses/OpenSSL-Apache-2.0.txt). OpenSSL copyright notices and component attribution are supplied in the corresponding OpenSSL source release; include that matching source and its notices when redistributing the combined build under GPL version 3. The Homebrew version used for a build is recorded by `brew info openssl@4`; do not assume a different installed version is the corresponding source.

## Protocol reference

Apple session-selection wire formats were checked against the independent [noVNC-ARD implementation](https://github.com/peetinc/noVNC-ARD). The local patch implements those wire formats in C and does not incorporate that project's JavaScript source.
