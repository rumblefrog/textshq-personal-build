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

function init() {
    export NPGGHA_TOKEN=$GH_TOKEN
    export YARN_ENABLE_IMMUTABLE_INSTALLS=false

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
yarn $@
EOF

    sudo mv /tmp/bun /usr/local/bin/bun
    sudo chmod +x /usr/local/bin/bun
}

function setup_keychain() {
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
    git clone --depth 1 https://github.com/TextsHQ/texts-app-desktop

    cd texts-app-desktop

    node scripts/first-setup.js --try-build

    yarn

    yarn run build-macos-binaries
}

function package_app() {
    yarn run _ package macos x64

    yarn run _ cross-build macos arm64
    cp -R _cross-build/packaged/* packaged/

    yarn run _ cross-build windows x64
    cp -R _cross-build/packaged/* packaged/

    yarn run _ cross-build linux x64
    cp -R _cross-build/packaged/* packaged/
}

init
setup_keychain
setup_packages
package_app

