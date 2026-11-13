#!/usr/bin/env bash
set -euo pipefail

dist="$1"
source_dir="FLEX-1.0.3-source/Plugins/FLEX"
version="$(sed -n 's/^Version: //p' "$source_dir/control" | tr -d '\r')"
package="$(sed -n 's/^Package: //p' "$source_dir/control" | tr -d '\r')"
staging="$(mktemp -d)"
trap 'rm -rf "$staging"' EXIT

for environment in rootful rootless roothide; do
    case "$environment" in
        rootful)  architecture=iphoneos-arm; prefix=; minimum=9.0 ;;
        rootless) architecture=iphoneos-arm64; prefix=/var/jb; minimum=15.0 ;;
        roothide) architecture=iphoneos-arm64e; prefix=; minimum=15.0 ;;
    esac
    root="$staging/$environment"
    inject="$prefix/Library/MobileSubstrate/DynamicLibraries"
    docs="$prefix/usr/share/doc/$package"
    mkdir -p "$root/DEBIAN" "$root$inject" "$root$docs"
    cp "$dist/ReFlex.dylib" "$root$inject/ReFlex.dylib"
    cp "$source_dir/ReFlex.plist" "$root$inject/ReFlex.plist"
    cp "$source_dir/ThirdPartyNotices/"*-LICENSE.txt "$root$docs/"

    {
        printf 'Package: %s\nVersion: %s\nArchitecture: %s\n' "$package" "$version" "$architecture"
        printf 'Name: ReFlex\nSection: Tweaks\n'
        printf 'Maintainer: qiu7c\nAuthor: FLEX Team & pxx917144686\n'
        printf 'Description: UIKit inspection and local network MCP\n'
        printf 'Depends: firmware (>= %s), mobilesubstrate\n' "$minimum"
    } > "$root/DEBIAN/control"

    output="$dist/ReFlex_${version}_${environment}.deb"
    dpkg-deb --build --root-owner-group -Zxz "$root" "$output"
    dpkg-deb --extract "$output" "$staging/check-$environment"
    cmp "$dist/ReFlex.dylib" "$staging/check-$environment$inject/ReFlex.dylib"
done
