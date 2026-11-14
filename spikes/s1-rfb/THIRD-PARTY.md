# Third-party notice — OpenSSL 3.5.9

The offline `sanjbox-ard-worker` statically links the explicitly approved, unmodified
OpenSSL 3.5.9 `libcrypto`. OpenSSL is distributed under Apache License 2.0; the exact
upstream text is preserved in [licenses/OpenSSL-LICENSE.txt](licenses/OpenSSL-LICENSE.txt).
The source archive/commit and license digest are pinned in
[openssl-provenance.json](openssl-provenance.json).

The pinned upstream README's copyright notice is:

> Copyright (c) 1998-2026 The OpenSSL Project Authors
>
> Copyright (c) 1995-1998 Eric A. Young, Tim J. Hudson
>
> All rights reserved.

No top-level upstream NOTICE file was present in the verified archive. Retain the
license and applicable attribution with redistributed binaries; retain individual
source copyright/license notices if redistributing source. This spike makes no
upstream source modifications and copies no upstream implementation into Git.
CommonCrypto is the operating system's public API and is used only by independent
fixture/test oracles, not as the production DH backend.
