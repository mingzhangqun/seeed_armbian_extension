#!/bin/bash
#
# build-deb.sh — Build libmali deb packages for selected GPU targets
#
# Usage: ./build-deb.sh [gpu_pattern ...]
#   Default: bifrost-g52 valhall-g610
#
# Filters debian/targets and debian/control to only build selected packages.
# Must run on arm64 (aarch64) host or cross-build environment.
#
set -euo pipefail

GPUS="${*:-bifrost-g52 valhall-g610}"

echo "=== Building libmali packages for: $GPUS ==="

# Build grep regex for aarch64 entries matching specified GPUs
regex=""
for gpu in $GPUS; do
    [ -n "$regex" ] && regex="$regex|"
    regex="${regex}aarch64.*${gpu}"
done

# Filter targets to selected GPUs only
grep -E "(${regex})" debian/targets > /tmp/_libmali_targets
mv /tmp/_libmali_targets debian/targets
echo "Selected targets:"
cat debian/targets

# Filter debian/control to only matching binary packages
export _LIBMALI_GPUS="$GPUS"
python3 << 'PYEOF'
import os, re

gpus = os.environ['_LIBMALI_GPUS'].split()
with open('debian/control') as f:
    content = f.read()

stanzas = re.split(r'\n\n+', content.strip())
keep = [stanzas[0]]  # Always keep Source stanza
for s in stanzas[1:]:
    first_line = s.split('\n')[0]
    if any(g in first_line for g in gpus):
        keep.append(s)

with open('debian/control', 'w') as f:
    f.write('\n\n'.join(keep) + '\n')
print(f'Keeping {len(keep) - 1} binary packages')
PYEOF

DEB_BUILD_OPTIONS="${DEB_BUILD_OPTIONS:-noddebs}" dpkg-buildpackage -us -uc -b

echo ""
echo "=== Done ==="
ls -lh ../*.deb 2>/dev/null || echo "No debs found"
