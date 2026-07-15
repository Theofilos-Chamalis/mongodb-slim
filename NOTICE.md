# NOTICE

mongodb-slim is an **unofficial, community-maintained** project. It is **not
affiliated with, sponsored by, or endorsed by MongoDB, Inc. or Chainguard, Inc.**

## Trademarks

MongoDB® and the leaf logo are registered trademarks of MongoDB, Inc. "Wolfi"
and "Chainguard" are marks of Chainguard, Inc. These names are used here only
for accurate, descriptive identification of the software being packaged.
mongodb-slim does not use their logos and does not claim any official status.

## Redistributed software

These images download and redistribute the following **unmodified, official**
binaries at build time:

| Component | Source | License |
|---|---|---|
| MongoDB Community Server (`mongod`) | `fastdl.mongodb.org` (official release tarballs) | Server Side Public License v1 (SSPL-1.0) |
| MongoDB Shell (`mongosh`) | `github.com/mongodb-js/mongosh` releases | Apache License 2.0 |
| Base OS packages (glibc, OpenSSL, libcurl, bash, tini, su-exec, …) | Chainguard Wolfi (`packages.wolfi.dev`) | various OSI-approved (mostly Apache-2.0 / MIT / BSD) |

The binaries are used as published by their vendors; mongodb-slim compiles nothing
and patches nothing. Each binary is verified against a vendor-published SHA-256
checksum at build time.

## SSPL and your use

MongoDB Community Server is licensed under the **SSPL**. Redistributing the
unmodified binaries (as these images do) is permitted. The SSPL's principal
condition concerns **offering the software as a service** to third parties. If
you do that, review the SSPL (in particular Section 13) for your obligations.
Full text: https://www.mongodb.com/licensing/server-side-public-license

You are responsible for your own compliance with the SSPL and the Apache-2.0
license when you pull, run, or further distribute these images.

## Warranty

Provided "as is", without warranty of any kind. See LICENSE.
