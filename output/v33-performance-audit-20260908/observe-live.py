import datetime,json,os,subprocess,time,urllib.request
from pathlib import Path
out=Path('/home/cfcosta/Code/_tmp/pokemon/gpt/output/v33-performance-audit-20260908')
c=json.loads(Path('/tmp/pokemon-active-training.json').read_text())
cgname=subprocess.check_output(['systemctl','--user','show',c['training_unit'],'-p','ControlGroup','--value'],text=True).strip();cg=Path('/sys/fs/cgroup')/cgname.lstrip('/')
clock=os.sysconf('SC_CLK_TCK');started=time.monotonic();rows=[]
for index in range(91):
    t=time.monotonic();row={'time':datetime.datetime.now(datetime.timezone.utc).isoformat(),'elapsed':t-started,'hz':clock,'processes':[]}
    for path in cg.rglob('cgroup.procs'):
        for pid in path.read_text().split():
            try:
                p=Path('/proc')/pid;s=(p/'stat').read_text().rsplit(')',1)[1].split();cmd=(p/'cmdline').read_bytes().replace(b'\0',b' ').decode(errors='replace')
                role='native' if 'battleSearchServer' in cmd else 'trainer' if 'transformer-train' in cmd else 'actor' if 'spawn_main' in cmd else 'other'
                row['processes'].append({'pid':int(pid),'role':role,'cpu_ticks':int(s[11])+int(s[12]),'rss':int(s[21])*os.sysconf('SC_PAGE_SIZE'),'state':s[0],'minor_faults':int(s[7]),'major_faults':int(s[9])})
            except OSError:pass
    for name in ['memory.current','memory.peak','memory.events','cpu.stat','cpu.pressure','memory.pressure']:
        try:row[name]=(cg/name).read_text().strip()
        except OSError:pass
    try:
        with urllib.request.urlopen('http://127.0.0.1:8765/api/dashboard',timeout=5) as r:d=json.load(r)
        row['status']=d.get('status');row['collection']={k:(d.get('collection') or {}).get(k) for k in ['completed','total','active_battles','transitions','examples','semantic_divergences']}
        row['actors']=[{k:a.get(k) for k in ['process','completed','active_battles','decision','transitions','updated_at']} for a in d.get('actors',[])]
    except Exception as e:row['error']=str(e)
    if index%5==0:
        row['gpu']=subprocess.run(['nvidia-smi','--query-gpu=utilization.gpu,utilization.memory,memory.used,power.draw','--format=csv,noheader,nounits'],capture_output=True,text=True).stdout.strip()
        row['gpu_processes']=subprocess.run(['nvidia-smi','pmon','-c','1','-s','um'],capture_output=True,text=True).stdout
    rows.append(row)
    with (out/'live-observation.jsonl').open('a') as f:f.write(json.dumps(row)+'\n')
    if index%15==0:print(json.dumps({'elapsed':row['elapsed'],'collection':row.get('collection'),'memory':row.get('memory.current')}),flush=True)
    if index<90:time.sleep(max(0,2-(time.monotonic()-t)))
(out/'live-observation-meta.json').write_text(json.dumps({'config':{k:c[k] for k in ['run','training_unit','source_commit']},'samples':len(rows),'notes':'Read-only live sampling; global GPU includes other apps. Audit probe intervals recorded separately.'},indent=2)+'\n')
