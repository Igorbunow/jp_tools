#!/usr/bin/env python3
"""Guard dhclient-script editing across L4T 6.2.2 and 6.2.3 layouts."""
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
content = path.read_text()
marker = 'if [ -f "${_initrd_dir}/sbin/dhclient-script" ]; then'
if marker in content:
    print("Patch C already applied.")
    raise SystemExit(0)

lines = content.splitlines(keepends=True)
for index, line in enumerate(lines):
    if "sed -i 's/\\/bin\\/sh/\\/bin\\/bash/'" not in line or '"${_initrd_dir}/sbin/dhclient-script"' not in line:
        continue
    indent = re.match(r"[ \t]*", line).group(0)
    command = line.strip().rstrip("\n")
    command = re.sub(r";\s*check_error\s*$", "; check_error", command)
    lines[index:index + 1] = [
        f'{indent}{marker}\n',
        f'{indent}\t{command}\n',
        f'{indent}fi\n',
    ]
    path.write_text("".join(lines))
    print("Patch C applied.")
    break
else:
    print(f"ERROR: Patch C anchor not found in {path}; unsupported L4T script layout", file=sys.stderr)
    raise SystemExit(1)
