# The DeepSeek Harness CLI as a Nix package: pnpm monorepo build of the
# deepseek-harness repo, producing `bin/dsh`.
#
# - `fetchPnpmDeps` materialises the pnpm store from pnpm-lock.yaml.
# - `pnpmConfigHook` points the offline install at that store.
# - The HMR service requires Node internals access, so the wrapper launches
#   node with `--expose-internals` (dsh itself never sets this flag).
{ lib
, stdenv
, nodejs
, pnpm
, pnpmConfigHook
, fetchPnpmDeps
, makeBinaryWrapper
, python3
, node-gyp
, src
}:

let
  version = "0.2.1-rc.2";
  pnpmDeps = fetchPnpmDeps {
    pname = "deepseek-harness";
    inherit version src;
    fetcherVersion = 4;
    pnpmInstallFlags = [
      "--fetch-timeout=600000"
      "--fetch-retries=10"
    ];
    hash = "sha256-C9Aw9AS4r7zubaEuT6mLXQ+AhhMVlTxPZRKTpzRUkcU=";
  };
in
stdenv.mkDerivation {
  pname = "dsh";
  inherit version src;

  nativeBuildInputs = [ nodejs pnpm pnpmConfigHook makeBinaryWrapper python3 node-gyp ];
  inherit pnpmDeps;

  buildPhase = ''
    runHook preBuild
    pnpm install --offline --frozen-lockfile
    # node-pty ships no linux prebuilds in its npm tarball, so its install
    # script must fall back to node-gyp — which needs python3 and the node
    # headers. Build it explicitly: pty.node and the unix spawn-helper both
    # come out of this rebuild, and the dsh patch loads both from
    # build/Release.
    (
      cd node_modules/.pnpm/node-pty@*/node_modules/node-pty
      export HOME="$TMPDIR"
      export npm_config_nodedir=${nodejs}
      export npm_config_python=python3
      node-gyp rebuild
    )
    # node-addon-require-builtin attempts to scan V8 memory dynamically to locate
    # internal module getters, which fails on Nixpkgs-built Node.js binaries
    # with `Unsupported/no-getter (x64 sysv getter is not a recognized this->field accessor)`.
    # Since the CLI wrapper launches Node with `--expose-internals`, try standard
    # `require(moduleId)` first to load internal modules directly.
    sed -i 's|function requireBuiltin(moduleId) {|function requireBuiltin(moduleId) { try { return require(moduleId); } catch {}|' \
      node_modules/.pnpm/node-addon-require-builtin@*/node_modules/node-addon-require-builtin/lib/index.js
    # Avoid spawning git inside the sandboxed build to query the HEAD commit.
    export DSH_CLIENT_COMMIT_HASH="687f282"
    pnpm run build
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p "$out"
    # The CLI resolves workspace packages through the pnpm node_modules
    # layout at runtime, so ship the built repo together with node_modules.
    cp -r . "$out/"
    rm -rf "$out/.git" "$out/.github" "$out/website" \
      "$out/.agents" "$out/.claude" \
      "$out/node_modules/.pnpm/node_modules/@deepseek-ai/website" \
      "$out/node_modules/.cache"
    mkdir -p "$out/bin"
    makeBinaryWrapper "${nodejs}/bin/node" "$out/bin/dsh" \
      --add-flags "--expose-internals" \
      --add-flags "$out/apps/cli/lib/bin.js" \
      --append-flags ""
    # ACP automation server app: JSON-RPC stdio bin over the agent spine.
    # Same HMR internals requirement as the CLI.
    makeBinaryWrapper "${nodejs}/bin/node" "$out/bin/dsh-acp-demo" \
      --add-flags "--expose-internals" \
      --add-flags "$out/packages/examples/acp-demo/lib/bin.js" \
      --append-flags ""
    runHook postInstall
  '';

  meta = {
    description = "DeepSeek Harness CLI (dsh)";
    homepage = "https://github.com/deepseek-ai/deepseek-harness";
    license = lib.licenses.mit;
    mainProgram = "dsh";
    platforms = lib.platforms.all;
  };
}
