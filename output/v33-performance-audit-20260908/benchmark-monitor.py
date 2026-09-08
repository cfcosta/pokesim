import hashlib,json,os,statistics,sys,tempfile,time
from pathlib import Path
ROOT=Path('/home/cfcosta/Code/_tmp/pokemon/gpt');sys.path.insert(0,str(ROOT/'packages/battle-training'))
from battle_training.monitor import atomic_monitor_json
out=ROOT/'output/v33-performance-audit-20260908';c=json.loads(Path('/tmp/pokemon-active-training.json').read_text());source=Path(c['run'])/'.monitor/actor-00.json';raw=source.read_bytes();payload=json.loads(raw);small={k:v for k,v in payload.items() if k!='recent_battles'}
record={'source':str(source),'source_bytes':len(raw),'source_sha256':hashlib.sha256(raw).hexdigest(),'recent_battles':len(payload.get('recent_battles',[])),'timeline_entries':sum(len(b.get('timeline',[])) for b in payload.get('recent_battles',[])),'variants':[],'scope':'Frozen live actor payload; serialized and atomically written with fsync on the same /media filesystem; 5 timed writes per variant. Compact formatting preserves the full payload. Progress-only requires moving replay storage to a separate artifact.'}
with tempfile.TemporaryDirectory(prefix='performance-probe-',dir='/media/pokemon-training') as directory:
 dest=Path(directory)/'actor.json'
 for kind,data in [('current-full-pretty',payload),('full-compact',payload),('progress-only-pretty',small)]:
  times=[];cpu=[]
  for _ in range(5):
   t=time.perf_counter();p=time.process_time()
   if kind=='full-compact':
    encoded=(json.dumps(data,separators=(',',':'),sort_keys=True)+'\n').encode()
    with tempfile.NamedTemporaryFile(dir=directory,delete=False) as f:
     tmp=Path(f.name);f.write(encoded);f.flush();os.fsync(f.fileno())
    os.replace(tmp,dest)
   else:atomic_monitor_json(dest,data)
   cpu.append(time.process_time()-p);times.append(time.perf_counter()-t)
  assert json.loads(dest.read_text())==data
  r={'kind':kind,'bytes':dest.stat().st_size,'seconds':times,'cpu_seconds':cpu,'median_seconds':statistics.median(times)};record['variants'].append(r);print(json.dumps(r),flush=True)
 # Read cost of the same full record and compact progress.
 for kind,data in [('full',payload),('progress',small)]:
  encoded=json.dumps(data).encode();samples=[]
  for _ in range(5):
   t=time.perf_counter();decoded=json.loads(encoded);samples.append(time.perf_counter()-t)
  record[kind+'_parse_median_seconds']=statistics.median(samples)
(out/'monitor-overhead.json').write_text(json.dumps(record,indent=2)+'\n')
