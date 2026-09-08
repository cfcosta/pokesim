import datetime,json,os,time
from pathlib import Path
out=Path('/home/cfcosta/Code/_tmp/pokemon/gpt/output/v33-performance-audit-20260908');c=json.loads(Path('/tmp/pokemon-active-training.json').read_text());cg=Path('/sys/fs/cgroup/user.slice/user-1000.slice/user@1000.service/app.slice')/(c['training_unit']+'.service');hz=os.sysconf('SC_CLK_TCK')
def sample():
 result={'time':time.monotonic(),'utc':datetime.datetime.now(datetime.timezone.utc).isoformat(),'processes':[],'actor_files':[]}
 for pid in (cg/'cgroup.procs').read_text().split():
  p=Path('/proc')/pid
  try:
   cmd=(p/'cmdline').read_bytes().decode(errors='replace');role='native' if 'battleSearchServer' in cmd else 'actor' if 'spawn_main' in cmd else 'other'
   if role=='other':continue
   io={k:int(v) for k,v in (l.split(':',1) for l in (p/'io').read_text().splitlines())};s=(p/'stat').read_text().rsplit(')',1)[1].split();result['processes'].append({'pid':int(pid),'role':role,'cpu_seconds':(int(s[11])+int(s[12]))/hz,**io})
  except OSError:pass
 for p in (Path(c['run'])/'.monitor').glob('actor-*.json'):
  st=p.stat();result['actor_files'].append({'file':p.name,'bytes':st.st_size,'mtime_ns':st.st_mtime_ns})
 return result
before=sample();time.sleep(30);after=sample();record={'before':before,'after':after};(out/'live-io.json').write_text(json.dumps(record,indent=2)+'\n');seconds=after['time']-before['time'];old={p['pid']:p for p in before['processes']}
for role in ['actor','native']:
 ps=[p for p in after['processes'] if p['role']==role and p['pid'] in old];print(role,'CPU cores',sum(p['cpu_seconds']-old[p['pid']]['cpu_seconds'] for p in ps)/seconds,'wchar MiB/s',sum(p['wchar']-old[p['pid']]['wchar'] for p in ps)/seconds/2**20,'disk-write MiB/s',sum(p['write_bytes']-old[p['pid']]['write_bytes'] for p in ps)/seconds/2**20)
