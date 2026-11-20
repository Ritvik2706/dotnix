#!/usr/bin/env bash
# The files' thumbnailer: stays up beside the island and makes the small
# pictures the finder shows in its rows and its grid. One request a line on
# stdin, `SOURCE<TAB>OUT<TAB>SIZE`; one answer a line on stdout, as soon as it
# is done: `ok<TAB>OUT<TAB>W<TAB>H` (the picture's own shape, so it can be
# drawn with its own corners) or `no<TAB>OUT`.
#
# Built in, by extension: pictures (libvips: jpeg png webp avif heic jxl tiff
# gif bmp…), svg, raw photos, PDF and PostScript pages, video frames, album
# art, comic and e-book covers, fonts, Office/LibreOffice documents (their own
# embedded picture, else LibreOffice draws page one), text and code (their
# first lines, drawn). Anything else: the system's freedesktop thumbnailers
# (/usr/share/thumbnailers), chosen by MIME type.
#
# Never starts children of its own that outlive it: everything runs in the
# foreground of this process group (see the island's process hygiene notes).

set -u
export LC_ALL=C
tmpd=$(mktemp -d "${XDG_RUNTIME_DIR:-/tmp}/lumen-thumbd.XXXXXX")
trap 'rm -rf "$tmpd"' EXIT
trap 'exit 0' TERM INT HUP

# The system's thumbnailers, by MIME type: `mime<TAB>Exec` (first one wins).
declare -A SYS
for f in /usr/share/thumbnailers/*.thumbnailer ~/.local/share/thumbnailers/*.thumbnailer; do
    [ -f "$f" ] || continue
    try=$(sed -n 's/^TryExec=//p' "$f" | head -n1)
    if [ -n "$try" ] && ! command -v "$try" >/dev/null 2>&1; then continue; fi
    exec_line=$(sed -n 's/^Exec=//p' "$f" | head -n1)
    [ -n "$exec_line" ] || continue
    IFS=';' read -ra mimes <<< "$(sed -n 's/^MimeType=//p' "$f" | head -n1)"
    for m in "${mimes[@]}"; do
        [ -n "$m" ] && [ -z "${SYS[$m]:-}" ] && SYS[$m]=$exec_line
    done
done

lower() { printf '%s' "${1,,}"; }
urlenc() {
    local s=$1 out="" c i
    for ((i = 0; i < ${#s}; i++)); do
        c=${s:i:1}
        case "$c" in [a-zA-Z0-9/._~-]) out+=$c ;; *) out+=$(printf '%%%02X' "'$c") ;; esac
    done
    printf 'file://%s' "$out"
}

# A picture scaled to fit SIZE×SIZE, from anything libvips (or ImageMagick) reads.
pic() { # src out size
    vipsthumbnail "$1[0]" -s "$3" -o "$2[strip]" 2>/dev/null \
        || vipsthumbnail "$1" -s "$3" -o "$2[strip]" 2>/dev/null \
        || magick "$1[0]" -auto-orient -thumbnail "${3}x${3}>" -strip "$2" 2>/dev/null
}

# The first picture inside an archive (a comic), or the one called cover (an e-book).
cover_in() { # src out size
    local list name
    list=$(bsdtar -tf "$1" 2>/dev/null | grep -iE '\.(jpe?g|png|webp|gif)$') || return 1
    name=$(printf '%s\n' "$list" | grep -iE 'cover' | head -n1)
    [ -n "$name" ] || name=$(printf '%s\n' "$list" | sort -V | head -n1)
    [ -n "$name" ] || return 1
    bsdtar -xOf "$1" "$name" > "$tmpd/cover" 2>/dev/null && pic "$tmpd/cover" "$2" "$3"
}

# An Office or LibreOffice file: the picture it carries of itself, else page one drawn.
office() { # src out size
    local x
    for x in Thumbnails/thumbnail.png docProps/thumbnail.jpeg docProps/thumbnail.png; do
        if unzip -p "$1" "$x" > "$tmpd/emb" 2>/dev/null && [ -s "$tmpd/emb" ]; then
            pic "$tmpd/emb" "$2" "$3" && return 0
        fi
    done
    rm -rf "$tmpd/lo"; mkdir -p "$tmpd/lo"
    timeout 40 soffice --headless "-env:UserInstallation=file://$tmpd/lo-profile" --convert-to png --outdir "$tmpd/lo" "$1" >/dev/null 2>&1 || return 1
    local png
    png=$(ls "$tmpd/lo"/*.png 2>/dev/null | head -n1)
    [ -n "$png" ] && pic "$png" "$2" "$3"
}

# Text and code: the first lines, drawn as a small page.
textpage() { # src out size
    head -c 1800 "$1" | head -n 22 | cut -c1-60 | tr '\t' ' ' > "$tmpd/txt" || return 1
    grep -q . "$tmpd/txt" || return 1
    grep -qP '\x00' "$tmpd/txt" 2>/dev/null && return 1
    local w=$(( $3 * 3 / 4 ))
    magick -size "${w}x$3" xc:'#1d1f27' \
        -font "JetBrainsMono-NF-Regular" -pointsize "$(( $3 / 24 ))" -fill '#c9ccd6' \
        -annotate "+$(( $3 / 22 ))+$(( $3 / 14 ))" "@$tmpd/txt" "$2" 2>/dev/null \
    || magick -size "${w}x$3" xc:'#1d1f27' -pointsize "$(( $3 / 24 ))" -fill '#c9ccd6' \
        -annotate "+$(( $3 / 22 ))+$(( $3 / 14 ))" "@$tmpd/txt" "$2" 2>/dev/null
}

fontsheet() { # src out size
    magick -size "$3x$3" xc:'#1d1f27' -font "$1" -fill '#f2f3f7' -gravity center \
        -pointsize "$(( $3 * 4 / 10 ))" -annotate +0-8 'Aa' \
        -pointsize "$(( $3 / 12 ))" -annotate "+0+$(( $3 * 3 / 10 ))" 'The quick brown fox' "$2" 2>/dev/null
}

# By the system's thumbnailers (%i %u %o %s), for the MIME type the file has.
system() { # src out size mime
    local cmd=${SYS[$4]:-}
    [ -n "$cmd" ] || return 1
    local uri; uri=$(urlenc "$1")
    local -a argv
    read -ra argv <<< "$cmd"
    local -a run=()
    local a
    for a in "${argv[@]}"; do
        a=${a//%i/$1}; a=${a//%u/$uri}; a=${a//%o/$2}; a=${a//%s/$3}
        run+=("$a")
    done
    timeout 20 "${run[@]}" >/dev/null 2>&1 && [ -s "$2" ]
}

make() { # src out size
    local src=$1 out=$2 size=$3 ext
    ext=$(lower "${src##*.}")
    [ "$ext" = "$src" ] && ext=""
    case "$ext" in
        jpg|jpeg|jpe|jfif|png|webp|avif|heic|heif|jxl|tif|tiff|gif|bmp|ico|tga|ppm|pgm|pbm|pnm|qoi|jp2|exr|hdr|apng)
            pic "$src" "$out" "$size" ;;
        svg|svgz)
            rsvg-convert -a -w "$size" -h "$size" "$src" -o "$out" 2>/dev/null || pic "$src" "$out" "$size" ;;
        cr2|cr3|nef|arw|dng|orf|rw2|raf|srw|pef)
            magick "$src[0]" -thumbnail "${size}x${size}>" "$out" 2>/dev/null || pic "$src" "$out" "$size" ;;
        psd|xcf|kra|ora)
            magick "$src[0]" -flatten -thumbnail "${size}x${size}>" "$out" 2>/dev/null ;;
        pdf|ai)
            pdftoppm -png -f 1 -l 1 -singlefile -scale-to "$size" "$src" "${out%.png}" 2>/dev/null ;;
        eps|ps)
            magick -density 72 "$src[0]" -thumbnail "${size}x${size}>" "$out" 2>/dev/null ;;
        mp4|mkv|webm|mov|avi|m4v|mpg|mpeg|wmv|flv|3gp|ts|mts|m2ts|ogv)
            ffmpegthumbnailer -i "$src" -o "$out" -s "$size" -c png -t 15 2>/dev/null ;;
        mp3|flac|ogg|opus|m4a|aac|wav|wma|alac|aiff|ape|wv)
            ffmpegthumbnailer -i "$src" -o "$out" -s "$size" -c png -t 10 -a 2>/dev/null \
                || ffmpeg -y -loglevel error -i "$src" -an -frames:v 1 "$out" 2>/dev/null ;;
        cbz|cbr|cb7|cbt|epub)
            cover_in "$src" "$out" "$size" ;;
        ttf|otf|woff|woff2|ttc|pfb)
            fontsheet "$src" "$out" "$size" ;;
        doc|docx|odt|rtf|ppt|pptx|odp|xls|xlsx|ods|odg|pages|key|numbers)
            office "$src" "$out" "$size" ;;
        txt|md|markdown|rst|org|log|csv|tsv|json|jsonc|yaml|yml|toml|ini|conf|cfg|nix|lua|luau|plm|py|rs|go|c|h|cpp|hpp|cc|js|ts|tsx|jsx|mjs|css|scss|html|xml|sh|bash|zsh|fish|vim|sql|tex|bib|java|kt|swift|rb|php|r|wgsl|glsl|svelte|vue|diff|patch|kdl|zig|hs|ml|ex|exs|el|dart|cs|scala|gradle|cmake|mk|dockerfile|env|lock|srt|vtt)
            textpage "$src" "$out" "$size" ;;
        *)
            local mime; mime=$(file -b --mime-type -- "$src" 2>/dev/null)
            case "$mime" in
                image/*) pic "$src" "$out" "$size" ;;
                video/*) ffmpegthumbnailer -i "$src" -o "$out" -s "$size" -c png -t 15 2>/dev/null ;;
                application/pdf) pdftoppm -png -f 1 -l 1 -singlefile -scale-to "$size" "$src" "${out%.png}" 2>/dev/null ;;
                text/*) textpage "$src" "$out" "$size" ;;
                *) system "$src" "$out" "$size" "$mime" ;;
            esac ;;
    esac
}

# "PNG image data, 256 x 171, …": its own shape.
shape() {
    file -b -- "$1" 2>/dev/null | sed -nE 's/.* ([0-9]+) x ([0-9]+).*/\1\t\2/p' | head -n1
}

while IFS=$'\t' read -r src out size; do
    [ -n "$src" ] || continue
    mkdir -p "${out%/*}"
    rm -f "$out"
    if [ -f "$src" ] && make "$src" "$out" "${size:-256}" && [ -s "$out" ]; then
        wh=$(shape "$out")
        [ -n "$wh" ] && printf 'ok\t%s\t%s\n' "$out" "$wh" || printf 'no\t%s\n' "$out"
    else
        rm -f "$out"
        printf 'no\t%s\n' "$out"
    fi
done
