#!/bin/bash

KEYCHAIN="textshq"
KEYCHAIN_PASSWORD="rumblefrog"

if [[ -z "$GH_TOKEN" ]]; then
    echo "GH_TOKEN is not set"
    exit 1
fi

if [[ -z "$CERT_P12_PATH" ]]; then
    echo "CERT_P12_PATH is not set"
    exit 1
fi

if [[ -z "$CERT_P12_PASS" ]]; then
    echo "CERT_P12_PASS is not set"
    exit 1
fi

if [[ -z "$APPLE_ID" ]]; then
    echo "WARN: APPLE_ID is not set for notorization"
fi

echo "[TEXTSHQ] GITHUB_WORKSPACE: $GITHUB_WORKSPACE"
echo "[TEXTSHQ] GITHUB_SHA: $GITHUB_SHA"

export NPGGHA_TOKEN=$GH_TOKEN
export YARN_ENABLE_IMMUTABLE_INSTALLS=false

function init() {
    echo "[TEXTSHQ] Initializing"

    git config --global url."https://api:${GH_TOKEN}@github.com/".insteadOf "https://github.com/"

    echo "registry=https://registry.yarnpkg.com/" > ~/.npmrc
    echo "@textshq:registry=https://npm.pkg.github.com" >> ~/.npmrc
    echo "//npm.pkg.github.com/:_authToken=${GH_TOKEN}" >> ~/.npmrc
    echo "always-auth=true" >> ~/.npmrc

    cat << EOF > ~/.yarnrc.yml
npmScopes:
  "textshq":
    npmAlwaysAuth: true
    npmAuthToken: $GH_TOKEN
    npmRegistryServer: "https://npm.pkg.github.com"
EOF

    cat << EOF > /tmp/bun
#!/bin/sh

yarn \$@
EOF

    sudo mv /tmp/bun /usr/local/bin/bun
    sudo chmod +x /usr/local/bin/bun
}

function setup_keychain() {
    echo "[TEXTSHQ] Setting up keychain"

    security create-keychain -p $KEYCHAIN_PASSWORD $KEYCHAIN

    security list-keychains -d user -s $KEYCHAIN $(security list-keychains -d user | sed s/\"//g)
    security list-keychains

    security set-keychain-settings $KEYCHAIN
    security unlock-keychain -p $KEYCHAIN_PASSWORD $KEYCHAIN

    security import $CERT_P12_PATH -k $KEYCHAIN -P $CERT_P12_PASS -T "/usr/bin/codesign"

    IOS_IDENTITY=$(security find-identity -v -p codesigning "$KEYCHAIN" | head -1 | grep '"' | sed -e 's/[^"]*"//' -e 's/".*//')
    IOS_UUID=$(security find-identity -v -p codesigning "$KEYCHAIN" | head -1 | grep '"' | awk '{print $2}')

    echo "IOS_IDENTITY=$IOS_IDENTITY"
    echo "IOS_UUID=$IOS_UUID"

    security set-key-partition-list -S apple-tool:,apple: -s -k $KEYCHAIN_PASSWORD $KEYCHAIN
}

function setup_packages() {
    echo "[TEXTSHQ] Setting up packages"

    git clone --depth 1 https://github.com/TextsHQ/texts-app-desktop

    cd texts-app-desktop

    node scripts/first-setup.js --skip-yarn

    cd ..
}

# https://github.com/Qix-/color/issues/233
function patch_packages() {
    echo "[TEXTSHQ] Patching packages"

    cd "$GITHUB_WORKSPACE/packages/platform-whatsapp-md/"

    PATCH_PATH=$(yarn patch color --json | jq -r '.path')

    patch -u "$PATCH_PATH/index.js" -i "$GITHUB_WORKSPACE/patches/color.patch"

    yarn patch-commit -s $PATCH_PATH
}

function build_packages() {
    echo "[TEXTSHQ] Building packages"

    cd "$GITHUB_WORKSPACE/texts-app-desktop"

    node scripts/first-setup.js --skip-cleanup

    patch_packages

    cd "$GITHUB_WORKSPACE/texts-app-desktop"

    node scripts/first-setup.js --skip-cleanup --try-build

    yarn

    # Workaround around https://github.com/yarnpkg/berry/issues/3865
    ./src/MacTools/build.sh
    yarn build-swift
}

function package_app() {
    echo "[TEXTSHQ] Packaging app"

    # Generates _ directory for packaging
    yarn webpack --config webpack.main.config.dev.js

    yarn run _ package macos x64

    # The sleeps are to try to avoid running into 503 when downloading electron from github
    sleep 5

    yarn run _ cross-build macos arm64

    sleep 5

    yarn run _ cross-build windows x64

    sleep 5

    yarn run _ cross-build linux x64

    rm -rf packaged/mac

    tar -zcvf packaged.tar.gz packaged
}

STAGE="${TEXTS_BUILD_STAGE:-ALL}"

if [ $STAGE == "INIT" ]; then
    echo "[TEXTSHQ] Init stage specified"

    init
    setup_keychain
    setup_packages
elif [ $STAGE == "BUILD" ]; then
    echo "[TEXTSHQ] Build stage specified"

    build_packages
    package_app
else
    echo "[TEXTSHQ] Running full build sequence"

    init
    setup_keychain
    setup_packages
    build_packages
    package_app
fi
