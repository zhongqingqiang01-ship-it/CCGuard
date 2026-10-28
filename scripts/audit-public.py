#!/usr/bin/env python3
"""Check the explicit public tree; report categories and paths, never secret values."""
import hashlib, ipaddress, pathlib, re, struct, subprocess, sys, zlib
root=pathlib.Path(__file__).resolve().parents[1]
roots={'Sources','Tests','Resources','scripts','docs','.github'}
files={'README.md','AGENTS.md','LICENSE','NOTICE.md','PRIVACY.md','SECURITY.md','CONTRIBUTING.md','Package.swift','.gitignore'}
ignored={'.git','.build','dist','Evidence','.local','__pycache__'}
tracked=[]
if (root/'.git').exists():
    output=subprocess.check_output(['git','ls-files','-z'],cwd=root)
    tracked=[root/path.decode() for path in output.split(b'\0') if path]
paths=tracked or [p for p in root.rglob('*') if p.is_file() and not any(part in ignored for part in p.relative_to(root).parts) and p.name!='.DS_Store']
patterns={
    'private-home-path':re.compile('/'+'Users'+r'/[^/\s\"\']+'),
    'private-key':re.compile(r'-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----'),
    'github-token':re.compile(r'(?:gh[pousr]_|github_pat_)[A-Za-z0-9_]{20,}'),
    'api-secret':re.compile(r'sk-[A-Za-z0-9_-]{20,}'),
    'cloud-access-key':re.compile(r'AKIA[0-9A-Z]{16}'),
    'email-address':re.compile(r'[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}'),
}
errors=[]
def fail(path,category):errors.append((str(path.relative_to(root)),category))
allowed_png={b'IHDR',b'IDAT',b'IEND',b'PLTE',b'tRNS',b'sRGB',b'gAMA',b'cHRM'}
for p in paths:
    rel=p.relative_to(root)
    if p.is_symlink():fail(p,'symlink');continue
    if rel.parts[0] not in roots and str(rel) not in files:fail(p,'not-in-public-allowlist');continue
    if any(part in ignored or part.startswith('._') for part in rel.parts):fail(p,'local-or-metadata-file');continue
    data=p.read_bytes()
    if p.suffix=='.png':
        if data[:8]!=b'\x89PNG\r\n\x1a\n':fail(p,'invalid-png');continue
        offset=8
        while offset<len(data):
            size=struct.unpack('>I',data[offset:offset+4])[0]
            kind=data[offset+4:offset+8];chunk=data[offset+8:offset+8+size]
            if kind not in allowed_png:fail(p,'image-ancillary-metadata')
            if len(chunk)!=size or zlib.crc32(kind+chunk)!=struct.unpack('>I',data[offset+8+size:offset+12+size])[0]:fail(p,'invalid-png-crc')
            offset+=size+12
        continue
    try:text=data.decode('utf-8')
    except UnicodeDecodeError:fail(p,'unapproved-binary');continue
    for category,pattern in patterns.items():
        for match in pattern.finditer(text):
            value=match.group()
            if category=='email-address' and value.endswith('@users.noreply.github.com'):continue
            if category=='email-address' and rel.as_posix()=='Tests/CCGuardCoreTests/DetectionTests.swift' and value=='user'+'@'+'ip.net.coffee':continue
            fail(p,category);break
    for value in re.findall(r'(?<![\d.])\d{1,3}(?:\.\d{1,3}){3}(?![\d.])',text):
        try:ip=ipaddress.IPv4Address(value)
        except ValueError:continue  # Deliberately malformed parser fixtures.
        documentation=any(ip in ipaddress.ip_network(prefix) for prefix in ['192.0.2.0/24','198.51.100.0/24','203.0.113.0/24'])
        # Synthetic classification fixture: ensures 172/8 is not all treated as private.
        synthetic=value=='172.200.0.1' and rel.as_posix() in ['scripts/verify-background-probe.mjs','scripts/audit-public.py']
        if not (documentation or ip.is_private or ip.is_loopback or value=='1.1.1.1' or synthetic):fail(p,'non-documentation-public-ip')
if errors:
    for path,category in sorted(set(errors)):print(f'FAIL {path}: {category}',file=sys.stderr)
    sys.exit(1)
print(f'Public export audit passed: {len(paths)} files; allowlist, text patterns, addresses and PNG metadata checked')
print('Pattern checks do not replace manual review or prove the absence of all security issues.')
