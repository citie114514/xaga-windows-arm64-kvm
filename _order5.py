import sys, os
sys.stdout.reconfigure(encoding='utf-8')
ROOT = r'C:\Users\citie\xaga-windows-arm64-kvm'

PATTERNS = [
    '(Join-Path $PSScriptRoot "$name.exe")',
    '(Join-Path $PSScriptRoot "platform-tools\\$name.exe")',
    '(Join-Path $PSScriptRoot "..\\platform-tools\\$name.exe")',
    '(Join-Path $PSScriptRoot "..\\tools\\platform-tools\\$name.exe")',
]

for rel in ('scripts/run-oneclick.ps1', 'scripts/flash-vendor-boot.ps1', 'scripts/flash-tee.ps1'):
    p = os.path.join(ROOT, rel)
    lines = open(p, encoding='utf-8').read().splitlines(keepends=True)
    removed = 0
    for pat in PATTERNS:
        for i, ln in enumerate(lines):
            if pat in ln and ln.strip().startswith('(Join-Path'):
                del lines[i]
                removed += 1
                break
    open(p, 'w', encoding='utf-8', newline='').write(''.join(lines))
    print(f'{rel}: removed {removed} early candidate lines')
