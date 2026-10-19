#!/bin/bash
set -euo pipefail

CONFIG="${LOGITECH_CONFIG:-$HOME/.config/logitech-switcher/config.json}"

found=$(ioreg -c IOHIDDevice -r -l | awk '
    /^\+-o / { name = ""; vid = ""; pid = ""; hidpp = 0; done = 0 }
    name == "" && /"Product" = / { split($0, a, "\""); name = a[4] }
    vid == "" && /"VendorID" = / { vid = $NF }
    pid == "" && /"ProductID" = / { pid = $NF }
    /"DeviceUsagePage"=65347,"DeviceUsage"=514/ { hidpp = 1 }
    !done && name != "" && vid == 1133 && pid != "" && hidpp {
        printf "%s|%d\n", name, pid
        done = 1
    }
' | sort -u)

if [ -z "$found" ]; then
    echo "configure: no Logitech HID++ device found, pair and connect the keyboard and mouse to this Mac" >&2
    exit 30
fi

entries=""
while IFS='|' read -r name pid; do
    case "$(echo "$name" | tr '[:upper:]' '[:lower:]')" in
        *master*|*mouse*|*anywhere*) key=mouse ;;
        *keys*|*keyboard*) key=keyboard ;;
        *) key=$(echo "$name" | tr '[:upper:] ' '[:lower:]-') ;;
    esac
    hexpid=$(printf '0x%04X' "$pid")
    echo "configure: $key = $name ($hexpid)" >&2
    entries+="${entries:+,}
    \"$key\": {\"vid\": \"0x046D\", \"pid\": \"$hexpid\", \"usagePage\": \"0xFF43\", \"usage\": \"0x0202\"}"
done <<< "$found"

mkdir -p "$(dirname "$CONFIG")"
printf '{\n  "devices": {%s\n  }\n}\n' "$entries" > "$CONFIG"
echo "configure: wrote $CONFIG" >&2
