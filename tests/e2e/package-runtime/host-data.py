"""Authenticate host ROM packages into an exclusive protected root prefix."""
import hashlib
import io
import json
import os
from pathlib import Path, PurePosixPath
import posixpath
import re
import runpy
import shutil
import subprocess
import time
import tarfile
import resource
import urllib.request

HERE=Path(__file__).resolve().parent
TRUST=runpy.run_path(str(HERE/'hosted-execute.py'))
KEY='/etc/apt/trusted.gpg.d/ubuntu-keyring-2018-archive.gpg'
FINGERPRINT='F6ECB3762474EDA9D21B7022871920D1991BC93C'
FINGERPRINT_SOURCE='https://documentation.ubuntu.com/chisel/en/v1.4.0/reference/security/'
PACKAGES=('qemu-system-common','qemu-system-data','qemu-system-gui','ovmf','seabios','ipxe-qemu')
RESOURCES=('usr/share/qemu','usr/share/OVMF','usr/share/ovmf','usr/share/seabios','usr/lib/ipxe/qemu')


def sha(path):
    with Path(path).open('rb') as stream:return hashlib.file_digest(stream,'sha256').hexdigest()


def fields(text):
    result={}
    for line in text.splitlines():
        if not line or line[0].isspace():continue
        key,value=line.split(':',1)
        if key in result:raise ValueError('duplicate package metadata field')
        result[key]=value.strip()
    return result


def package_pin(text,name,version):
    blocks=[fields(block) for block in text.strip().split('\n\n') if block.strip()]
    wanted=[block for block in blocks if block.get('Package')==name and block.get('Version')==version]
    if not wanted:raise ValueError('exact installed package absent from authenticated metadata: '+name)
    pins=[]
    for block in wanted:
        filename=block.get('Filename','');size=block.get('Size','');digest=block.get('SHA256','')
        if (block.get('Architecture') not in ('amd64','all') or not re.fullmatch('[0-9a-f]{64}',digest) or
                not size.isdigit() or not 0<int(size)<=64*1024**2 or
                not filename.startswith('pool/') or '..' in PurePosixPath(filename).parts or not filename.endswith('.deb')):
            raise ValueError('incomplete authenticated package pin: '+name)
        pins.append({key:block[key] for key in ('Package','Version','Architecture','Filename','Size','SHA256')})
    if any(pin!=pins[0] for pin in pins):raise ValueError('ambiguous authenticated package pin: '+name)
    return pins[0]


def selected(name):
    return any(name==root or name.startswith(root+'/') for root in RESOURCES)


def unpack_tar(data,objects,owner,directories=None):
    """Record authenticated data members; never execute scripts or extract through links."""
    with tarfile.open(fileobj=io.BytesIO(data),mode='r:*') as archive:
        for member in archive:
            name=member.name.removeprefix('./')
            if name in ('','.'):continue
            if name.startswith('/') or '..' in PurePosixPath(name).parts:raise ValueError('archive path escapes root')
            if member.isdir():
                if directories is not None and (selected(name) or any(root.startswith(name+'/') for root in RESOURCES)):
                    directories.setdefault(name,[]).append({'package':owner,'archiveMode':member.mode})
                continue
            if not selected(name):continue
            if member.isfile():
                if not 0<=member.size<=64*1024**2:raise ValueError('resource file exceeds bound')
                payload=archive.extractfile(member).read(member.size+1)
                if len(payload)!=member.size:raise ValueError('resource file truncated')
                value={'type':'file','bytes':payload,'sha256':hashlib.sha256(payload).hexdigest(),'owner':owner,'archiveMode':member.mode}
            elif member.issym() or member.islnk():
                target=member.linkname
                target=target.lstrip('/') if target.startswith('/') else posixpath.join(posixpath.dirname(name),target) if member.issym() else target.removeprefix('./')
                target=posixpath.normpath(target)
                if target.startswith('../') or target=='..' or not selected(target):raise ValueError('resource link escapes declared package closure')
                value={'type':'link','target':target,'owner':owner,'archiveMode':member.mode}
            else:raise ValueError('unsupported resource archive member')
            if name in objects and {k:v for k,v in objects[name].items() if k!='owner'}!={k:v for k,v in value.items() if k!='owner'}:
                raise ValueError('conflicting package resource member: '+name)
            objects[name]=value


def resolve(objects,name,chain=()):
    if name in chain or len(chain)>32:raise ValueError('resource link cycle')
    if name not in objects:raise ValueError('resource link target missing: '+name)
    value=objects[name]
    return value if value['type']=='file' else resolve(objects,value['target'],chain+(name,))


def write_tree(objects,prefix):
    """Materialize every declared resource as sealed content; links never borrow host bytes."""
    prefix=Path(prefix)
    outputs={}
    for name in sorted(objects):
        for parent in PurePosixPath(name).parents:
            if str(parent) in objects:raise ValueError('resource file used as parent')
        source=resolve(objects,name);target=prefix/name
        target.parent.mkdir(mode=0o755,parents=True,exist_ok=True)
        with target.open('xb') as stream:
            stream.write(source['bytes']);stream.flush();os.fsync(stream.fileno())
        target.chmod(0o444)
        outputs[name]={'sha256':source['sha256'],'package':objects[name]['owner'],
                       'archiveMode':objects[name]['archiveMode'],'resolvedPackage':source['owner'],
                       'originalLinkTarget':objects[name].get('target')}
    for required in ('usr/share/OVMF/OVMF_CODE_4M.fd','usr/share/OVMF/OVMF_VARS_4M.fd',
                     'usr/share/seabios/vgabios-stdvga.bin','usr/lib/ipxe/qemu/efi-virtio.rom'):
        if required not in outputs:raise ValueError('required private firmware/ROM missing: '+required)
    return outputs


def apt_config(prefix):
    """Ignore host repositories, keys and configuration; no trusted/insecure override."""
    prefix=Path(prefix)
    (prefix/'apt/etc/parts').mkdir(parents=True,mode=0o755)
    (prefix/'apt/lists/partial').mkdir(parents=True,mode=0o755)
    (prefix/'apt/cache/archives/partial').mkdir(parents=True,mode=0o755)
    config=prefix/'apt/config'
    values={'Dir::Etc':str(prefix/'apt/etc'),'Dir::Etc::main':'main.conf','Dir::Etc::parts':'parts',
            'Dir::Etc::sourcelist':'ubuntu.sources','Dir::Etc::sourceparts':'-',
            'Dir::Etc::trusted':'empty.gpg','Dir::Etc::trustedparts':'-',
            'Dir::State::lists':str(prefix/'apt/lists'),'Dir::Cache':str(prefix/'apt/cache'),
            'APT::Architecture':'amd64','APT::Architectures::':'amd64',
            'APT::Get::AllowUnauthenticated':'false','Acquire::AllowInsecureRepositories':'false',
            'Acquire::AllowDowngradeToInsecureRepositories':'false','Acquire::Check-Valid-Until':'true',
            'Acquire::Languages':'none'}
    config.write_text('\n'.join(key+' "'+value+'";' for key,value in values.items())+'\n')
    (prefix/'apt/etc/main.conf').write_text('')
    (prefix/'apt/etc/ubuntu.sources').write_text('Types: deb\nURIs: https://archive.ubuntu.com/ubuntu\nSuites: noble noble-updates noble-security\nComponents: main universe\nArchitectures: amd64\nSigned-By: '+str(prefix/'archive-key.gpg')+'\n')
    return config


def release_checksums(text):
    result={};reading=False
    for line in text.splitlines():
        if line=='SHA256:':reading=True;continue
        if reading and not line.startswith(' '):break
        if reading:
            pieces=line.split()
            if len(pieces)!=3 or not re.fullmatch('[0-9a-f]{64}',pieces[0]) or not pieces[1].isdigit():
                raise ValueError('signed Release SHA256 entry malformed')
            digest,size,name=pieces
            if name in result:raise ValueError('duplicate signed Release path')
            result[name]=(digest,int(size))
    if not result:raise ValueError('signed Release SHA256 table absent')
    return result


def package_blocks(path):
    with Path(path).open('r',encoding='utf-8') as stream:
        lines=[];size=0
        for line in stream:
            size+=len(line)
            if size>1048576:raise ValueError('package metadata stanza exceeds bound')
            if line.strip():lines.append(line)
            else:
                if lines:yield ''.join(lines)
                lines=[];size=0
        if lines:yield ''.join(lines)


def bounded_blob(argv,path,limit,env,run=subprocess.run,remaining=lambda:120):
    TRUST['protected'](argv[0])
    seconds=min(120,remaining())
    if seconds<=0:raise TimeoutError('host prefix absolute deadline expired before extraction')
    def bound():resource.setrlimit(resource.RLIMIT_FSIZE,(limit,limit))
    with Path(path).open('xb') as output:
        run(argv,stdout=output,stderr=subprocess.DEVNULL,check=True,timeout=seconds,env=env,preexec_fn=bound)
    if Path(path).stat().st_size>limit:raise ValueError('bounded metadata/extraction output exceeded limit')


def download_chunk(response,remaining):
    # HTTPResponse.read1 performs at most one underlying read. Reset the
    # actual socket deadline so a slow peer cannot multiply a stale timeout.
    seconds=min(30,remaining())
    if seconds<=0:raise TimeoutError('host prefix absolute deadline expired before download read')
    if response.isclosed():return b''
    response.fp.raw._sock.settimeout(seconds)
    return response.read1(65536)


def download_body(response,output,pin,remaining):
    total=0;digest=hashlib.sha256()
    while True:
        chunk=download_chunk(response,remaining)
        if not chunk:break
        total+=len(chunk)
        if total>int(pin['Size']):raise ValueError('package download exceeds authenticated size')
        output.write(chunk);digest.update(chunk)
    if total!=int(pin['Size']) or digest.hexdigest()!=pin['SHA256']:
        raise ValueError('authenticated archive bytes differ')


def produce(prefix,run=subprocess.run):
    TRUST['hosted'](os.environ)
    prefix=Path(prefix).absolute()
    if os.getuid()!=0 or not re.fullmatch('/run/wootc-package-host-[0-9]+-[0-9]+',str(prefix)):
        raise ValueError('root-owned exclusive hosted /run prefix required')
    TRUST['protected'](KEY)
    if shutil.disk_usage('/run').free<640*1024**2:raise ValueError('protected host prefix capacity below bound')
    prefix.mkdir(mode=0o755,exist_ok=False)
    deadline=time.monotonic()+600
    def budget():
        remaining=deadline-time.monotonic()
        if remaining<=0:raise TimeoutError('host prefix absolute deadline expired')
        if sum(path.stat().st_size for path in prefix.rglob('*') if path.is_file())>512*1024**2:
            raise ValueError('protected host prefix exceeds 512MiB quota')
        return remaining
    record={'schemaVersion':1,'sourceCommit':os.environ['GITHUB_SHA'],'producerSha256':sha(__file__),'prefix':str(prefix),'complete':False,'packages':[],'resources':{},'runtimeExecuted':False}
    def save():(prefix/'host-data.json').write_text(json.dumps(record,sort_keys=True,indent=2)+'\n')
    save()
    env={'PATH':'/usr/bin:/bin','LANG':'C','LC_ALL':'C'}
    def command(argv,timeout=120):
        for tool in (argv[0],):TRUST['protected'](tool)
        return run(argv,check=True,capture_output=True,text=True,timeout=min(timeout,budget()),env=env)
    try:
        (prefix/'gnupg').mkdir(mode=0o700)
        key_digest=sha(KEY)
        shutil.copyfile(KEY,prefix/'archive-key.gpg');(prefix/'archive-key.gpg').chmod(0o444)
        if sha(KEY)!=key_digest or sha(prefix/'archive-key.gpg')!=key_digest:raise ValueError('archive key changed across copy')
        observed=command(['/usr/bin/gpg','--homedir',str(prefix/'gnupg'),'--batch','--show-keys','--with-colons',str(prefix/'archive-key.gpg')]).stdout
        fingerprints=[line.split(':')[9] for line in observed.splitlines() if line.startswith('fpr:')]
        if fingerprints!=[FINGERPRINT]:raise ValueError('official archive key fingerprint differs')
        record.update(archiveKeyFingerprint=FINGERPRINT,archiveKeySha256=sha(prefix/'archive-key.gpg'),archiveKeyFingerprintSource=FINGERPRINT_SOURCE)
        config=apt_config(prefix);env['APT_CONFIG']=str(config)
        command(['/usr/bin/apt-get','update'],timeout=300)
        releases=[];release_tables={}
        for path in sorted((prefix/'apt/lists').glob('*_InRelease')):
            status=command(['/usr/bin/gpgv','--homedir',str(prefix/'gnupg'),'--status-fd','1','--keyring',str(prefix/'archive-key.gpg'),str(path)]).stdout
            if not any(line.startswith('[GNUPG:] VALIDSIG '+FINGERPRINT+' ') for line in status.splitlines()):
                raise ValueError('actual signed Release fingerprint absent')
            text=path.read_text()
            payload=text.split('\n\n',1)[1].split('\n-----BEGIN PGP SIGNATURE-----',1)[0]
            release_fields=fields(payload)
            if (release_fields.get('Origin')!='Ubuntu' or release_fields.get('Label')!='Ubuntu' or
                    release_fields.get('Suite') not in ('noble','noble-updates','noble-security') or
                    release_fields.get('Codename')!='noble'):
                raise ValueError('signed Release identity outside declared official suites')
            release_tables[path.name]=release_checksums(text)
            releases.append({'name':path.name,'sha256':sha(path),'signatureStatus':status})
            record['signedReleases']=list(releases);save()
        if len(releases)!=3:raise ValueError('complete signed official suites absent')
        record['signedReleases']=releases;record['aptConfigSha256']=sha(config)
        record['authenticatedIndexFiles']={path.name:sha(path) for path in (prefix/'apt/lists').iterdir() if path.is_file()}
        versions={}
        for package in PACKAGES:
            version=command(['/usr/bin/dpkg-query','-W','-f=${Version}',package]).stdout
            if not re.fullmatch('[A-Za-z0-9.+:~_-]+',version):raise ValueError('installed package version malformed')
            versions[package]=version
        targets=[fields(block) for block in command(['/usr/bin/apt-get','indextargets']).stdout.strip().split('\n\n')]
        pins={};indices=[]
        for target in targets:
            if target.get('Identifier')!='Packages' or target.get('Architecture')!='amd64':continue
            suite=target.get('Release');key=target.get('MetaKey')
            if (target.get('Origin')!='Ubuntu' or target.get('Trusted')!='yes' or
                    suite not in ('noble','noble-updates','noble-security') or
                    target.get('Repo-URI')!='https://archive.ubuntu.com/ubuntu/' or
                    target.get('Component') not in ('main','universe')):
                raise ValueError('index outside authenticated official source contract')
            release='archive.ubuntu.com_ubuntu_dists_'+suite+'_InRelease'
            expected=release_tables[release].get(key)
            if expected is None or not 0<expected[1]<=256*1024**2:raise ValueError('signed raw index pin absent/oversized')
            source=Path(target['Filename']).resolve(strict=True)
            if source.parent!=prefix/'apt/lists':raise ValueError('index filename outside private APT state')
            TRUST['protected'](source)
            raw=prefix/'raw-index'
            bounded_blob(['/usr/lib/apt/apt-helper','cat-file',str(source)],raw,expected[1],env,run,remaining=budget)
            if raw.stat().st_size!=expected[1] or sha(raw)!=expected[0]:raise ValueError('Packages bytes differ from signed Release')
            indices.append({'suite':suite,'metaKey':key,'rawSha256':expected[0],'rawBytes':expected[1],
                            'storedSha256':sha(source),'signedReleaseSha256':next(r['sha256'] for r in releases if r['name']==release)})
            record['signedPackageIndices']=list(indices);save()
            for block in package_blocks(raw):
                metadata=fields(block);package=metadata.get('Package')
                if package in versions and metadata.get('Version')==versions[package]:
                    pin=package_pin(block,package,versions[package])
                    if package in pins and pins[package]!=pin:raise ValueError('cross-index package pin ambiguous')
                    pins[package]=pin
            raw.unlink()
        if set(pins)!=set(PACKAGES) or len(indices)!=6:raise ValueError('complete authenticated package/index closure absent')
        if sum(int(pin['Size']) for pin in pins.values())>64*1024**2:raise ValueError('authenticated host archives exceed declared acquisition bound')
        record['signedPackageIndices']=indices;record['authenticatedPackagePins']=pins;save()
        objects={};directories={};downloads=prefix/'downloads';downloads.mkdir(mode=0o700)
        for package in PACKAGES:
            pin=pins[package];archive=downloads/(package+'.deb');partial=downloads/(package+'.partial')
            url='https://archive.ubuntu.com/ubuntu/'+pin['Filename']
            with urllib.request.urlopen(url,timeout=min(30,budget())) as response,partial.open('xb') as output:
                if response.geturl()!=url:raise ValueError('official package locator unexpectedly redirected')
                download_body(response,output,pin,budget)
                output.flush();os.fsync(output.fileno())
            partial.replace(archive);archive.chmod(0o444)
            native=command(['/usr/bin/dpkg-deb','--show','--showformat=${Package} ${Version} ${Architecture}',str(archive)]).stdout
            if native!=pin['Package']+' '+pin['Version']+' '+pin['Architecture']:raise ValueError('archive identity differs')
            tar=prefix/'package-data.tar'
            bounded_blob(['/usr/bin/dpkg-deb','--fsys-tarfile',str(archive)],tar,256*1024**2,env,run,remaining=budget)
            budget()
            unpack_tar(tar.read_bytes(),objects,package,directories);tar.unlink()
            record['archiveDirectoryModes']=directories
            if sum(len(value.get('bytes',b'')) for value in objects.values())>128*1024**2:
                raise ValueError('complete extracted resource content exceeds bound')
            record['packages'].append(pin);save()
        budget()
        record['resources']=write_tree(objects,prefix)
        for path in prefix.rglob('*'):
            if path.is_dir():path.chmod(0o755)
        for name,pin in record['resources'].items():
            path=TRUST['protected'](prefix/name)
            if sha(path)!=pin['sha256']:raise ValueError('sealed source bytes differ')
        record['complete']=True;save();(prefix/'host-data.json').chmod(0o444)
        return record
    except BaseException as error:
        record.update(failureType=type(error).__name__,failure=str(error));save();raise


if __name__=='__main__':
    import argparse
    parser=argparse.ArgumentParser();parser.add_argument('exclusive_prefix');args=parser.parse_args()
    print(json.dumps({'complete':produce(args.exclusive_prefix)['complete'],'runtimeExecuted':False}))
