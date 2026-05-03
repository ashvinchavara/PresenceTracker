import zipfile
import re

endpoints = set()

with zipfile.ZipFile('etlab.apk', 'r') as z:
    for filename in z.namelist():
        if filename.endswith('.dex') or 'bundle' in filename or filename.endswith('.js') or filename.endswith('.txt'):
            try:
                content = z.read(filename)
                strings = re.findall(b'[ -~]{5,}', content)
                for s in strings:
                    try:
                        s_dec = s.decode('ascii', errors='ignore')
                        s_lower = s_dec.lower()
                        if 'api/' in s_lower or 'v1/' in s_lower or 'student/' in s_lower or 'result' in s_lower or 'semester' in s_lower:
                            if '/' in s_dec and len(s_dec) < 150:
                                endpoints.add(s_dec)
                    except:
                        pass
            except:
                pass

with open('endpoints.txt', 'w', encoding='utf-8') as f:
    for ep in sorted(endpoints):
        f.write(ep + '\n')
