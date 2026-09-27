import configparser, hashlib, json, pathlib, re, shlex, subprocess
import sys
root=pathlib.Path(sys.argv[1])
config=configparser.ConfigParser(interpolation=None)
config.read(root/'images.conf')
password=shlex.split(config['bitlk-aes-xts-128']['RP'])[0]
assert re.fullmatch(r'[0-9]{6}(?:-[0-9]{6}){7}',password)
results=[]
for name,key in [('canonical-55',password),('stripped-48',password.replace('-',''))]:
    proc=subprocess.run(['cryptsetup','bitlkOpen','-r',str(root/'bitlk-aes-xts-128.img'),
                         '--test-passphrase','--key-file=-'],input=key.encode(),capture_output=True,timeout=30)
    stderr=re.sub(r'[0-9]{6}(?:-[0-9]{6}){7}|[0-9]{48}', '[REDACTED]',proc.stderr.decode(errors='replace'))
    results.append({'case':name,'inputCharacters':len(key),'exit':proc.returncode,'stderr':stderr.strip()})
assert results[0]['exit']==0 and results[1]['exit']!=0,results
print(json.dumps({'cryptsetup':subprocess.check_output(['cryptsetup','--version'],text=True).strip(),
  'imageSha256':hashlib.sha256((root/'bitlk-aes-xts-128.img').read_bytes()).hexdigest(),'results':results},indent=2))
