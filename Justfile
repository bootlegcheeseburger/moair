# MoAir recipes -- `brew install just`, then run `just`.

set shell := ["bash", "-cu"]

app_name         := "MoAir"
bundle_id        := "com.bootlegcheeseburger.moair"
arch             := `uname -m`
debug_bin        := ".build/" + arch + "-apple-macosx/debug/MoAir"
release_bin      := ".build/" + arch + "-apple-macosx/release/MoAir"
app_dir          := ".build/" + app_name + ".app"
installed_app    := "/Applications/" + app_name + ".app"
plist            := "Resources/Info.plist"
signing_identity := env_var_or_default("MOAIR_SIGN_IDENTITY", "Developer ID Application: Daniel Timmons (X2L9Q89VB9)")
notary_profile   := env_var_or_default("MOAIR_NOTARY_PROFILE", "moair-notarize")

# list recipes
default:
    @just --list --unsorted

# --- dev ---

# debug build
[group: 'dev']
build:
    swift build

# run debug binary (no menubar — use `relaunch` for that)
[group: 'dev']
run: build
    {{debug_bin}}

# run with synthesised motion + fake device
[group: 'dev']
fake: build
    MOAIR_FAKE=1 {{debug_bin}}

# unit tests
[group: 'dev']
test:
    swift test

# rm -rf .build
[group: 'dev']
clean:
    rm -rf .build

# --- app ---

# stop any running MoAir (debug, .build/.app, or installed)
[group: 'app']
kill-app:
    -pkill -f '{{debug_bin}}' || true
    -pkill -f '{{app_dir}}' || true
    -pkill -f '{{installed_app}}' || true

# regenerate MoAir.icns + menubar PNGs from design TIFFs (idempotent)
[group: 'app']
icon:
    @if [ ! -f Resources/MoAir.icns ] || [ design/moair-icon.tiff -nt Resources/MoAir.icns ]; then \
        rm -rf Resources/MoAir.iconset; \
        mkdir -p Resources/MoAir.iconset; \
        for sz in 16 32 128 256 512; do \
            sips -s format png -z $sz $sz design/moair-icon.tiff --out Resources/MoAir.iconset/icon_${sz}x${sz}.png >/dev/null; \
            sips -s format png -z $((sz*2)) $((sz*2)) design/moair-icon.tiff --out Resources/MoAir.iconset/icon_${sz}x${sz}@2x.png >/dev/null; \
        done; \
        iconutil --convert icns Resources/MoAir.iconset --output Resources/MoAir.icns; \
        cp Resources/MoAir.icns Sources/MoAir/Resources/MoAir.icns; \
        echo "regenerated Resources/MoAir.icns (+ SwiftPM mirror)"; \
    fi
    @# Menubar PNGs: trim transparent border, Lanczos-downscale to inner
    @# size, then re-pad to canvas (16-in-18 @1x, 32-in-36 @2x). Needs
    @# ImageMagick — sips can't auto-trim.
    @for src in design/moair-menu.tiff design/moair-menu-off.tiff design/moair-menu-track.tiff; do \
        base=$(basename "$src" .tiff); \
        out1="Sources/MoAir/Resources/${base}.png"; \
        out2="Sources/MoAir/Resources/${base}@2x.png"; \
        if [ ! -f "$out1" ] || [ "$src" -nt "$out1" ]; then \
            magick "$src" -trim +repage -filter Lanczos -resize 21x21 \
                -background none -gravity center -extent 22x22 -strip "$out1"; \
            magick "$src" -trim +repage -filter Lanczos -resize 42x42 \
                -background none -gravity center -extent 44x44 -strip "$out2"; \
            echo "regenerated $out1 + @2x"; \
        fi; \
    done
    @# 3x3 moai head spritesheet — sliced at runtime. Cells are 28pt
    @# (84pt / 3) so the visible head inside each cell ends up ~21pt
    @# — matching the static menu icons' content height. Source has
    @# transparent padding around each head we can't easily trim, so
    @# we lean on a bigger canvas instead.
    @if [ ! -f Sources/MoAir/Resources/moai-grid.png ] || [ design/moai-grid.png -nt Sources/MoAir/Resources/moai-grid.png ]; then \
        magick design/moai-grid.png -filter Lanczos -resize 84x84 \
            -strip Sources/MoAir/Resources/moai-grid.png; \
        magick design/moai-grid.png -filter Lanczos -resize 168x168 \
            -strip Sources/MoAir/Resources/moai-grid@2x.png; \
        echo "regenerated Sources/MoAir/Resources/moai-grid.png + @2x"; \
    fi

# release compile -> wrap in signed MoAir.app
[group: 'app']
bundle: icon
    swift build -c release
    @rm -rf {{app_dir}}
    @mkdir -p {{app_dir}}/Contents/MacOS {{app_dir}}/Contents/Resources
    @cp {{release_bin}} {{app_dir}}/Contents/MacOS/{{app_name}}
    @cp Resources/Info.plist {{app_dir}}/Contents/Info.plist
    @cp Resources/MoAir.entitlements {{app_dir}}/Contents/Resources/MoAir.entitlements
    @cp Resources/MoAir.icns {{app_dir}}/Contents/Resources/MoAir.icns
    @cp Sources/MoAir/Resources/blc.png {{app_dir}}/Contents/Resources/blc.png
    @res_bundle=".build/{{arch}}-apple-macosx/release/MoAir_MoAir.bundle" ; \
        if [ -d "$res_bundle" ]; then \
            cp -R "$res_bundle" {{app_dir}}/Contents/Resources/ ; \
        fi
    @codesign --force --deep --timestamp \
        --entitlements Resources/MoAir.entitlements \
        --options runtime \
        --sign "{{signing_identity}}" \
        {{app_dir}}
    @echo "built {{app_dir}}"

# bundle + launch from .build
[group: 'app']
relaunch: kill-app bundle
    open {{app_dir}}
    @sleep 1; echo "launched (pid: $(pgrep -f {{app_dir}} || echo ?))"

# bundle + copy to /Applications
[group: 'app']
install: bundle
    @rm -rf {{installed_app}}
    @cp -R {{app_dir}} /Applications/
    @echo "installed {{installed_app}}"

# reinstall + launch from /Applications (preserves TCC grants)
[group: 'app']
relaunch-installed: kill-app install
    open {{installed_app}}
    @sleep 1; echo "launched (pid: $(pgrep -f {{installed_app}} || echo ?))"

# --- diag ---

# list audio output devices with name + transport (helps debug detection)
[group: 'diag']
devices:
    @system_profiler SPAudioDataType -json 2>/dev/null \
        | jq -r '.SPAudioDataType[0]._items[] | select(.coreaudio_device_output) | "\(._name) | transport=\(.coreaudio_device_transport // "?") | manufacturer=\(.coreaudio_device_manufacturer // "?")"'

# show running MoAir + default audio output
[group: 'diag']
status:
    @echo "Processes:"
    @pgrep -lf MoAir || echo "  (none)"
    @echo ""
    @echo "Default audio output:"
    @system_profiler SPAudioDataType 2>/dev/null | awk '/Default Output Device: Yes/{found=1} found{print; if(/^$/){exit}}' | head -8 || true

# tail MoAir's own log output
[group: 'diag']
logs:
    log stream --style compact --process MoAir

# tail bluetoothd codec lines
[group: 'diag']
log-codec:
    log stream --style compact --predicate 'subsystem == "com.apple.bluetooth" AND eventMessage CONTAINS "Codec"' --info

# reset Motion + Bluetooth TCC grants
[group: 'diag']
reset-tcc:
    -tccutil reset Motion {{bundle_id}}
    -tccutil reset Bluetooth {{bundle_id}}
    @echo "reset Motion + Bluetooth TCC for {{bundle_id}}"

# send two test /orientation packets (needs liblo)
[group: 'diag']
osc-test host="127.0.0.1" port="7000":
    oscsend {{host}} {{port}} /orientation fff 0.0 0.0 0.0
    oscsend {{host}} {{port}} /orientation fff 45.0 10.0 -5.0
    @echo "sent two /orientation packets to {{host}}:{{port}}"

# dump every OSC packet on PORT (needs liblo)
[group: 'diag']
oscdump port="7000":
    oscdump {{port}}

# tcpdump UDP on lo0:PORT (sudo)
[group: 'diag']
udpdump port="7000":
    sudo tcpdump -i lo0 -A "udp port {{port}}"

# --- release ---

# one-time: store Apple ID + team + app-specific password in keychain
[group: 'release']
notary-setup:
    xcrun notarytool store-credentials {{notary_profile}}

# bundle -> styled DMG -> sign -> notarize -> staple -> dist/
[group: 'release']
build-release: bundle
    @v=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' {{plist}}) ; \
        dmg="dist/{{app_name}}-v$v.dmg" ; \
        rw_dmg="/tmp/{{app_name}}-rw-$$.dmg" ; \
        staging=$(mktemp -d) ; \
        mkdir -p dist ; \
        rm -f "dist/{{app_name}}-v"*.dmg "$rw_dmg" ; \
        cp -R {{app_dir}} "$staging/" ; \
        ln -s /Applications "$staging/Applications" ; \
        echo "[1/5] creating writable image" ; \
        hdiutil create -volname "{{app_name}}" -srcfolder "$staging" -fs HFS+ -format UDRW -ov -quiet "$rw_dmg" ; \
        rm -rf "$staging" ; \
        echo "[2/5] styling window (256pt icons, side-by-side layout)" ; \
        bash scripts/style-dmg.sh "{{app_name}}" "{{app_name}}" "$rw_dmg" ; \
        echo "[3/5] compressing → $dmg" ; \
        hdiutil convert "$rw_dmg" -format UDZO -imagekey zlib-level=9 -o "$dmg" -quiet ; \
        rm -f "$rw_dmg" ; \
        echo "[4/5] signing $dmg" ; \
        codesign --force --timestamp --sign "{{signing_identity}}" "$dmg" ; \
        echo "[5/5] notarizing (Apple is judging us)" ; \
        xcrun notarytool submit "$dmg" --keychain-profile "{{notary_profile}}" --wait ; \
        xcrun stapler staple "$dmg" ; \
        spctl -a -t open --context context:primary-signature -v "$dmg" ; \
        echo "" ; \
        echo "ready: $dmg"

# per-release asset download counts (needs `gh` CLI, public repo or auth)
[group: 'release']
downloads:
    @slug=$(git remote get-url origin 2>/dev/null | sed -E 's#.*github\.com[:/]([^/]+/[^/]+)(\.git)?$#\1#; s/\.git$//') ; \
        case "$slug" in */*) ;; *) echo "no GitHub remote configured (git remote add origin ...)" >&2 ; exit 1 ;; esac ; \
        { printf "tag\tasset\tdownloads\n" ; \
          gh api "repos/$slug/releases" --paginate \
              --jq '.[] | .tag_name as $t | .assets[] | "\($t)\t\(.name)\t\(.download_count)"' ; \
        } | column -t -s "$(printf '\t')" ; \
        total=$(gh api "repos/$slug/releases" --paginate --jq '[.[].assets[].download_count] | add // 0') ; \
        echo "----" ; \
        echo "total: $total"

# --- ver ---

# print current version
[group: 'ver']
version:
    @v=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' {{plist}}) ; \
        b=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' {{plist}}) ; \
        echo "MoAir v$v ($b)"

# bump CFBundleShortVersionString + CFBundleVersion (major|minor|patch)
[group: 'ver']
bump LEVEL:
    @v=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' {{plist}}) ; \
        b=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' {{plist}}) ; \
        IFS=. read -r major minor patch <<< "$v" ; \
        case "{{LEVEL}}" in \
            major) new="$((major+1)).0.0" ;; \
            minor) new="$major.$((minor+1)).0" ;; \
            patch) new="$major.$minor.$((patch+1))" ;; \
            *) echo "usage: just bump {major|minor|patch}" >&2 ; exit 1 ;; \
        esac ; \
        nb=$((b+1)) ; \
        /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $new" {{plist}} ; \
        /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $nb" {{plist}} ; \
        sed -i '' -E "s/static let hardcodedVersion = \".*\"/static let hardcodedVersion = \"$new\"/" Sources/MoAir/Settings/Branding.swift ; \
        echo "$v ($b) -> $new ($nb)"

# --- git ---

# push main + tags
[group: 'git']
push:
    git push origin main
    git push --tags

# bump LEVEL, commit plist + Branding, tag vX.Y.Z
[group: 'git']
cut LEVEL: (bump LEVEL)
    @v=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' {{plist}}) ; \
        git add {{plist}} Sources/MoAir/Settings/Branding.swift ; \
        git commit -m "Bump version to v$v" ; \
        git tag "v$v" ; \
        echo "tagged v$v -- run \`just push\` to publish"
