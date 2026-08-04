# logos-delivery (KYM fork): Reliable Channels + arm64-Android build

This is a fork of [logos-messaging/logos-delivery](https://github.com/logos-messaging/logos-delivery)
at commit **`8ad99f10`** — the `feat`/string-ABI branch that exposes the **Reliable Channels**
API (SDS-backed reliable, causally-ordered delivery over Waku). On top of that upstream we carry
a small set of build patches that let us produce a working **arm64-Android** `liblogosdelivery.so`,
plus the empirical build recipe for reproducing it. This fork is used by
[KYM](https://github.com/vpavlin) — a local-first, peer-to-peer budgeting app on Logos — as its
sync transport.

Upstream is dual-licensed MIT/Apache-2.0 (see `LICENSE-MIT`, `LICENSE-APACHE`); this fork
preserves that licensing unchanged.

---

## Part 1 — Our patches vs upstream

Three source patches distinguish this fork from `8ad99f10`:

### `flake.nix` — drop the custom `nimbleOverlay`

Upstream's flake pinned **nimble 0.22.3**, built from source. In our Nix dev shell that build
fails on a missing `sat` submodule. We removed the `nimbleOverlay` and use **nixpkgs' nimble**
instead. Nim **2.2.4** (from nixpkgs) already matches the repo's `RequiredNimVersion`, so
`scripts/install_nim.sh` detects a satisfactory toolchain and skips its own Nim build.

### `scripts/build_rln_android.sh` — stub the docker/`cross` RLN build

Upstream builds `librln.so` for Android via a Docker + `cross` toolchain that isn't available in
our environment. We stubbed that path to consume a **pre-staged arm64 `librln.so`** placed at
`build/android/<abi>/librln.so`. RLN's FFI surface is stable, so linking a known-good arm64
`librln.so` produces a correct delivery library. (The pre-staged `.so` lives under `build/`, which
is git-ignored, so it is not committed here — stage your own known-good arm64 `librln.so`.)

### `logos_delivery.nimble` (`buildMobileAndroid`) — link the C++ runtime

The Android link omitted the C++ runtime even though the library references C++ std symbols
(`std::…`, `__cxa_*`). The resulting `.so` had no `NEEDED libc++_shared.so` entry and failed to
`dlopen` on Android with "cannot locate symbol". We add `--passL:-lc++_shared` to the Android Nim
link:

```nim
exec "nim c" & " --out:" & outDir &
  "/liblogosdelivery.so --threads:on --app:lib --opt:speed --noMain --mm:refc " &
  "-d:chronicles_sinks=textlines[dynamic] --header -d:chronosEventEngine=epoll --passL:-L" &
  outdir & " --passL:-lrln --passL:-llog --passL:-lc++_shared --cpu:" & cpu &
  " --nimMainPrefix:liblogosdelivery --os:android -d:androidNDK " & params &
  getNimParams() & " " & srcDir & "/liblogosdelivery.nim"
```

**This must be fixed at link time.** Do **not** try to `patchelf --add-needed libc++_shared.so`
onto an already-built Android `.so` — patchelf corrupts `DT_GNU_HASH`, which bionic's linker
requires, and the library then fails to load with "empty/missing DT hash".

---

## Part 2 — Building `liblogosdelivery.so` for arm64-Android (the 12 walls)

**Prerequisites**

- Nix (with flakes).
- The Android NDK, e.g. `ndk/27.1.12297006`.
- Nix-built dependencies on hand: `nix build`ed `nixpkgs#openssl.out`, `nixpkgs#git`,
  `nixpkgs#cacert`.

**Invocation**

Run `make liblogosdelivery-android-arm64` **inside `nix develop`**, with the following environment:

- Nix `git` first on `PATH` — the system `git` dies against Nix glibc with
  `GLIBC_ABI_DT_X86_64_PLT not found`.
- `*_SSL_CERT_FILE=$CACERT/etc/ssl/certs/ca-bundle.crt` (point the SSL cert vars at the nix
  `cacert` bundle).
- `LIBRARY_PATH=$OSSL/lib` and `LD_LIBRARY_PATH=$OSSL/lib` (the nix openssl output).
- `ANDROID_NDK_HOME=<ndk>` (e.g. the `ndk/27.1.12297006` path).

**The 12 walls, in the order you hit them**

1. **nimble / `sat` submodule** — the pinned nimble 0.22.3 build fails on a missing `sat`
   submodule → drop the `nimbleOverlay`, use nixpkgs nimble (Part 1).
2. **`-lssl` not found** → set `LIBRARY_PATH` to the nix openssl lib dir.
3. **nimble 0.22.3 build** — same root cause as (1); confirmed fixed by dropping the overlay.
4. **git-over-nix-glibc** — system git crashes on nix glibc → put nix `git` on `PATH`.
5. **"not a git repository"** — the build needs version metadata from git → `git init`, commit,
   and `git tag`.
6. **`flake.nix` untracked** — once it is a git repo, Nix flakes ignore untracked files, so a
   modified-but-untracked `flake.nix` is invisible → `git add -A` everything.
7. **docker RLN** — the Android RLN build wants docker/`cross` → stub it + pre-stage
   `librln.so` (Part 1).
8. **`No nat_traversal package`** → run `make build-deps` first.
9. **compile only runs in the `/nix/store`-in-`LIBRLN_FILE` branch** — the Makefile only reaches
   the compile step when `LIBRLN_FILE` points into `/nix/store` →
   `make … LIBRLN_FILE=/nix/store/forced-rln`.
10. **NAT libs built for the wrong arch** — the NAT libraries (`libminiupnpc.a`, etc.) get built
    x86_64 with x86-only `-mssse3`. Delete them and rebuild for **aarch64** with
    `PORTABLE_NAT_MARCH=` (empty), **before** the delivery compile.
11. **missing `libc++_shared` NEEDED** → `--passL:-lc++_shared` at link time (Part 1).
12. **`waku_stop` / `waku_destroy` not exported** — this build unifies node lifecycle under the
    `logosdelivery_*` symbols. The JNI shim must call `logosdelivery_stop_node` and
    `logosdelivery_destroy`, **not** `waku_stop` / `waku_destroy`.

**Verifying the produced `.so`**

```sh
readelf -h liblogosdelivery.so        | grep Machine      # -> AArch64
strings liblogosdelivery.so | grep -c setNoopEncryption    # -> > 0
readelf -d liblogosdelivery.so | grep -c GNU_HASH          # -> 1
readelf -d liblogosdelivery.so | grep -c libc++_shared     # -> 1  (NEEDED present)
```

Strip with the **NDK `llvm-strip`** — it preserves `DT_GNU_HASH`. Do not strip with `patchelf`
or a host `strip` that rewrites the hash.

---

## Part 3 — How KYM uses Reliable Channels

**Transport gating.** KYM selects its transport with the env flag `KYM_USE_CHANNELS`. When
channels are enabled, `kym_core`'s `joinBudgetTransport()` calls:

```
delivery_module.channelCreateAsync(topic, topic, deviceId)
```

where **`channelId == contentTopic ==`** the household's derived Waku content topic
`/kym/1/<budgetId>/proto`, and **`senderId ==`** the per-device id. Outbound messages go through
`channelSend`; inbound arrive via `onChannelMessageReceived` → `ingestRaw`. The raw (no-channels)
fallback path uses `subscribeContentTopic` + `send` directly.

**App-level sync on top of the channel.** Over the channel, KYM runs its **own** application-level
sync protocol — Range-Based Set Reconciliation (RBSR). It exchanges sealed JSON envelopes:

```json
{ "v": 1, "type": "SUMMARY" | "EVENT" | "SYNC_REQ", "...": "..." }
```

Each envelope is encrypted with the household key (**ChaCha20-Poly1305**, with the topic as the
**AAD**) and base64-encoded. The SDS Reliable Channel provides delivery **reliability** and
**causal ordering**; **KYM provides confidentiality itself**. Because KYM already encrypts its
payloads, the channel's own encryption layer is the **no-op provider**
(`setNoopEncryption`, which `ReliableChannelManager.start()` auto-installs) — the channel does not
double-encrypt.

**Where it runs.**

- **Desktop** (Basecamp app + a headless hub) load the `delivery_module` plugin
  ([logos-co/logos-delivery-module](https://github.com/logos-co), branch
  `feat-add-channel-api-support`), which pins `logos-delivery @8ad99f10`.
- **Mobile** (React Native) binds the `liblogosdelivery` FFI directly through a JNI shim.

**Status.**

- Desktop ↔ desktop reliable-channel sync is **verified end-to-end** — both live sync and
  offline catch-up.
- Mobile **builds and loads** the noop-enabled library, and `channelSend` works. The mobile
  channel **receive** path (`onChannelMessageReceived`) is **still being debugged** and is not yet
  working end-to-end.
