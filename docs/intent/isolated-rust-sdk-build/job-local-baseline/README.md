# Job-local Rust/Core baseline

Use this environment recipe in the existing SDK owner's isolated job.
It installs only into that job's owned workspace; it does not need a
Docker socket, a new API, a different agent image or host toolchain changes.
The Core baseline does not establish Ruby bridge, server, prototype,
worker-quiescence or operating-adoption acceptance. Those remain with #5326.

## Profile and limits

The measured agent image is `sha256:988eef143158dfd4691fd790fe1788a9c56f0705434de9fd306a1f7a2383a2a5`:
ARM64, UID 1001, Ruby 3.4.13, `ENABLE_SHARED=no`. Record the actual selected
runner image and process profile; another Ruby ABI or architecture needs
its own evidence. The manifest records all artifact identities.

The successful run used read-only root, no daemon socket, all capabilities
dropped, no-new-privileges, one CPU and 128 PIDs. Installation and dependency
fetch used 512 MiB; compilation used 2 GiB. The operator checked at least 3 GiB
of backing-store space and 4 GiB of host memory headroom before compilation.
Retain the assigned job limits and any smaller remaining deadline; these
measurements do not authorize increasing capacity, native attempts or budgets.
If the assigned environment is insufficient, defer through the existing owner.

The actual image has `git`, `curl`, `xz`, `tar`, `unzip`, `python3`, `readelf`
and a C compiler. The measured pinned libclang path is absent: the Ruby
prototype owner must handle any additional native-build prerequisite rather
than treating a successful Core check as proof of Ruby-extension loading.

## Prepare the public inputs

Reserve the recipe's previously absent paths in the isolated job-owned
`/workspace`: `downloads`, `ruby`, `tools/protoc`, `toolchain-inputs`,
`toolchain`, `unpack`, `cargo`, `target`, and `source.before.sha`.
Do not overwrite an existing checkout, build directory or another run's files.
Use the normal workspace/artifact lifecycle if these names are already owned.
Never run these scripts on the host or stage the generated data into Paid.

`prepare-inputs.sh` downloads the official checksummed Rust 1.95 ARM64
components and protoc 34, fetches the exact SDK/Core commits, verifies the
Ruby-to-Core gitlink, exports their source archives and verifies Cargo.lock.
Its public URLs, SHA-256 values and source identities are in `manifest.json`;
it has no dependency on the operator's private input tar or `/tmp` files.
The preparation script has been syntax checked; the complete network assembly
script has not been separately executed end to end. The recorded baseline
used the same verified public inputs already assembled by the operator.

Set `RECIPE_DIR` to this recipe's directory in the checked-out Paid artifact.
Run preparation with the existing job's ordinary public-download access:

```sh
export RECIPE_DIR="$(pwd)/docs/intent/isolated-rust-sdk-build/job-local-baseline"
export WORK_ROOT=/workspace
# Use at most this bound, or the smaller remaining assigned job deadline.
timeout --signal=TERM --kill-after=5 300s sh "$RECIPE_DIR/prepare-inputs.sh"
```

The resulting source root is `/workspace/ruby/temporalio`, with Core at
`ext/sdk-core`. Git metadata is not exported into the source tree. The
scripts reject checksum or gitlink mismatches before invoking the build.

## Run the verified phase bodies

Export the same environment used by the successful isolated run:

```sh
export HOME=/tmp/home
export CARGO_HOME=/workspace/cargo
export CARGO_TARGET_DIR=/workspace/target
export CARGO_BUILD_JOBS=1
export RUSTC=/workspace/toolchain/bin/rustc
export RUSTDOC=/workspace/toolchain/bin/rustdoc
export PROTOC=/workspace/tools/protoc/bin/protoc
export PROTOC_INCLUDE=/workspace/tools/protoc/include
export PATH=/workspace/toolchain/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
cd /workspace/ruby/temporalio
timeout --signal=TERM --kill-after=5 180s sh "$RECIPE_DIR/install.sh"
timeout --signal=TERM --kill-after=5 300s sh "$RECIPE_DIR/fetch.sh"
timeout --signal=TERM --kill-after=5 900s sh "$RECIPE_DIR/check.sh"
```

The three shell command bodies are unchanged from the successful acceptance
run and are individually checksummed in the manifest. Installation verifies
each Rust archive before executing its installer. Fetch verifies Cargo.lock
and snapshots source-file hashes; check runs
`cargo check --locked --offline --package temporalio-sdk-core` and verifies
that every recorded source-file hash remains unchanged.

The proof used separate supported-backend phases: installation and check
had network disabled; fetch had public-crate access. The scripts do not
create containers or grant network privileges. Use the existing runner's
assigned isolation and artifact-transfer controls, and record any difference
from those measured phases rather than claiming offline Cargo enforces a
container-wide network policy.

## Evidence and owner handoff

On 2026-11-25 the measured image/profile, exact SDK
`61db6dd4b75e3b15731e58f26934b33c17663237` and Core
`c675c32469af707e1c979a7b808c70b4a0608b82` completed install, fetch and
locked offline Core check with exit 0 for each phase. Source hashes were
unchanged, no OOM was observed, and all four actual private containers and
owned volume were absent at 11:06:51 UTC. The Core check took 5 minutes 16 seconds.

These are environment-baseline results. Existing #5326 retains the actual
prototype, Ruby ABI/native loading, server, finite-attempt and task-safe
quiescence requirements. No containing SDK release, operating SDK pin,
worker update, authority grant or budget reset follows from this handoff.
Retain the job's selected revision/profile, command outcomes and cleanup
receipt when the owner uses this recipe. Preserve earlier failed histories.
