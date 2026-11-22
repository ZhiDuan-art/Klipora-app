"""Repackage the original MIT backend, retaining all binary dependencies.

Requires Python3.12/PyInstaller. Only the server entry gains a bootstrap hook;
all original archive members are retained byte-for-byte. Source fixes live in
Resources/backend-patches for review. The installed original is never edited.
"""
from pathlib import Path
import argparse, marshal, shutil, struct, subprocess, zlib, types
from PyInstaller.archive.writers import CArchiveWriter
from PyInstaller.utils.osx import fix_exe_for_code_signing

parser=argparse.ArgumentParser();parser.add_argument('original',type=Path);parser.add_argument('output',type=Path);args=parser.parse_args()
args.output.parent.mkdir(parents=True,exist_ok=True)
shutil.copy2(args.original,args.output)
subprocess.run(['codesign','--remove-signature',str(args.output)],check=True)
data=args.output.read_bytes();magic=b'MEI\x0c\x0b\x0a\x0b\x0e';cookie=data.rfind(magic)
_,length,toc_offset,toc_length,version,pylib=struct.unpack('!8sIIII64s',data[cookie:cookie+88])
assert version==312,'Use the matching Python3.12 compiler'
start=cookie+88-length;pos=start+toc_offset;entries=[];payload=bytearray()
hook=(Path(__file__).parent/'local_backend_hook.py').read_text()
while pos<start+toc_offset+toc_length:
 size,offset,compressed,uncompressed,flag,kind=struct.unpack('!iIIIBc',data[pos:pos+18]);name=data[pos+18:pos+size].rstrip(b'\0').decode();pos+=size
 raw=data[start+offset:start+offset+compressed]
 if name=='server' and kind==b's':
  original=zlib.decompress(raw) if flag else raw
  # Rebuilding from an existing integration replaces its hook rather than nesting it.
  for _ in range(8):
   previous=marshal.loads(original)
   if previous.co_filename!='voicebox-desktop-bootstrap.py':break
   candidates=[v for v in previous.co_consts if isinstance(v,bytes)]
   if len(candidates)!=1 or not isinstance(marshal.loads(candidates[0]),types.CodeType):
    raise ValueError('Cannot identify the original backend entry')
   original=candidates[0]
  else:raise ValueError('Too many nested bootstrap entries')
  wrapped=compile(hook+'\nimport marshal\nexec(marshal.loads('+repr(original)+'), globals())\n','voicebox-desktop-bootstrap.py','exec')
  code=marshal.dumps(wrapped);uncompressed=len(code);raw=zlib.compress(code,9) if flag else code;compressed=len(raw)
 entries.append((len(payload),compressed,uncompressed,flag,kind.decode(),name));payload.extend(raw)
toc=CArchiveWriter._serialize_toc(entries)
new_cookie=struct.pack('!8sIIII64s',magic,len(payload)+len(toc)+88,len(payload),len(toc),version,pylib)
args.output.write_bytes(data[:start]+payload+toc+new_cookie)
args.output.chmod(0o755);fix_exe_for_code_signing(str(args.output))
subprocess.run(['codesign','--force','--sign','-',str(args.output)],check=True)
print('Bundled backend:',args.output)
