# MoAir recipes -- `brew install just`, then run `just`.

set shell := ["bash", "-cu"]

# shared signing recipes + signing_identity / notary_profile vars
import? '~/Code/blc/just/core.just'
import? '~/Code/blc/just/swift.just'
import? '~/Code/blc/just/macos.just'
# shared versioning: version, bump, cut, notes, publish (config: blc.toml [release])
import? '~/Code/blc/just/release.just'

app_name      := "MoAir"
bundle_id     := "com.bootlegcheeseburger.moair"
arch          := `uname -m`
debug_bin     := ".build/" + arch + "-apple-macosx/debug/MoAir"
release_bin   := ".build/" + arch + "-apple-macosx/release/MoAir"
app_dir       := ".build/" + app_name + ".app"
installed_app := "/Applications/" + app_name + ".app"
dev_app       := home_directory() / "Builds/_latest" / app_name + " Dev.app"
plist         := "Resources/Info.plist"

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

# rm -rf .build
[group: 'dev']
clean:
    rm -rf .build

# --- app ---

# stop any running MoAir (debug, .build/.app, dev, or installed)
[group: 'app']
kill-app:
    -pkill -f '{{debug_bin}}' || true
    -pkill -f '{{app_dir}}' || true
    -pkill -f '{{installed_app}}' || true
    -pkill -f '{{dev_app}}' || true

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

# release compile -> wrap in signed MoAir.app (install and release use it)
[private]
_bundle-signed: (_assemble app_dir)
    @codesign --force --deep --timestamp \
        --entitlements Resources/MoAir.entitlements \
        --options runtime \
        --sign "{{signing_identity}}" \
        {{app_dir}}
    @echo "built {{app_dir}}"

# release compile -> unsigned "MoAir Dev.app" (<id>.dev, ad-hoc) in ~/Builds/moair/dev/<describe>; refreshes _latest
[group: 'app']
bundle:
    #!/usr/bin/env bash
    set -euo pipefail
    builds="$HOME/Code/blc/scripts/builds.sh"
    out="$("$builds" dir {{app_name}} dev)"
    app="$out/{{app_name}} Dev.app"
    just -f "{{justfile()}}" _assemble "$app"
    info="$app/Contents/Info.plist"
    id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$info")"
    plutil -replace CFBundleIdentifier -string "$id.dev" "$info"
    plutil -replace CFBundleName -string "{{app_name}} Dev" "$info"
    plutil -replace CFBundleDisplayName -string "{{app_name}} Dev" "$info"
    codesign --force --deep --sign - --entitlements Resources/MoAir.entitlements "$app"
    echo "built $app"
    "$builds" latest {{app_name}} "$app"
    "$builds" prune --apply {{app_name}} | grep -v 'outside the layout' || true

# release compile + assemble an unsigned .app at DEST (bundle and _bundle-signed sign it)
[private]
_assemble DEST: icon
    swift build -c release
    @rm -rf "{{DEST}}"
    @mkdir -p "{{DEST}}/Contents/MacOS" "{{DEST}}/Contents/Resources"
    @cp {{release_bin}} "{{DEST}}/Contents/MacOS/{{app_name}}"
    @cp Resources/Info.plist "{{DEST}}/Contents/Info.plist"
    @python3 -I ~/Code/blc/scripts/release.py stamp "{{DEST}}/Contents/Info.plist" >/dev/null
    @cp Resources/MoAir.entitlements "{{DEST}}/Contents/Resources/MoAir.entitlements"
    @cp Resources/MoAir.icns "{{DEST}}/Contents/Resources/MoAir.icns"
    @cp Sources/MoAir/Resources/blc.png "{{DEST}}/Contents/Resources/blc.png"
    @res_bundle=".build/{{arch}}-apple-macosx/release/MoAir_MoAir.bundle" ; \
        if [ -d "$res_bundle" ]; then \
            cp -R "$res_bundle" "{{DEST}}/Contents/Resources/" ; \
        fi

# bundle + launch the dev copy from ~/Builds/_latest
[group: 'app']
relaunch: kill-app bundle
    open "{{dev_app}}"
    @sleep 1; echo "launched (pid: $(pgrep -f '{{dev_app}}' || echo ?))"

# signed bundle + copy to /Applications
[group: 'app']
install: _bundle-signed
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

# signed bundle, then the shop's ship step (release-dmg, macos-package.sh) -> ~/Builds/moair/releases/v<version>/MoAir-<version>.dmg
[group: 'release']
release: _bundle-signed (release-dmg app_dir "--presigned")

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

# push main + tags
[group: 'release']
push:
    git push origin main
    git push --tags
