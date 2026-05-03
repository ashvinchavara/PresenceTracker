import re

with open('etlab.apk', 'rb') as f:
    content = f.read()

strings = re.findall(b'[ -~]{5,}', content)
strings = [s.decode('ascii', errors='ignore') for s in strings]

endpoints = set()
for s in strings:
    s_lower = s.lower()
    if 'api/' in s_lower or 'result' in s_lower or 'semester' in s_lower or 'student' in s_lower or 'exam' in s_lower:
        if '/' in s:
            endpoints.add(s)

with open('endpoints.txt', 'w', encoding='utf-8') as f:
    for ep in sorted(endpoints):
        f.write(ep + '\n')
