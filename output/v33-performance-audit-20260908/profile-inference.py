import json,statistics,sys,time
from pathlib import Path
import numpy as np
import torch
ROOT=Path('/home/cfcosta/Code/_tmp/pokemon/gpt');sys.path.insert(0,str(ROOT/'packages/battle-training'))
from battle_training.network import load_network
from battle_training.native import SearchServer
out=ROOT/'output/v33-performance-audit-20260908';c=json.loads(Path('/tmp/pokemon-active-training.json').read_text());run=Path(c['run'])
torch.set_num_threads(1);torch.set_num_interop_threads(1)
network=load_network(run/'checkpoints/policy-000.pt',torch.device('cuda'))
with SearchServer() as server:
 roots=[(server.reset if i==0 else server.reset_append)(772131,i,6,6,level100=True) for i in range(16)]
report={'device':torch.cuda.get_device_name(),'precision':network.config.precision,'sequence_length':network.sequence_length,'rows':[],'scope':'Synchronized evaluate_joint wall time: staging, both policies, full encoder/value and D2H; concurrent live training; 3 warmups and 20 timed repetitions per variant.'}
for batch in [16,64,256]:
 features=np.stack([roots[i%16].player_features for i in range(batch)]);own=[roots[i%16].player_mask for i in range(batch)];opp=[roots[i%16].enemy_mask for i in range(batch)]
 outputs={}
 for mode in ['compiled','eager','compiled']:
  network.configure_inference(mode);cold=time.perf_counter();network.evaluate_joint(features,own,opp);torch.cuda.synchronize();cold=time.perf_counter()-cold
  for _ in range(3):network.evaluate_joint(features,own,opp)
  times=[]
  for _ in range(20):
   torch.cuda.synchronize();t=time.perf_counter();result=network.evaluate_joint(features,own,opp);torch.cuda.synchronize();times.append(time.perf_counter()-t)
  outputs[mode]=result
  report['rows'].append({'batch':batch,'engine':mode,'cold_seconds':cold,'median_ms':statistics.median(times)*1000,'p95_ms':float(np.percentile(times,95))*1000,'samples_seconds':times})
  print(json.dumps({k:v for k,v in report['rows'][-1].items() if k!='samples_seconds'}),flush=True)
 report['rows'][-1]['compiled_eager_max_difference']=max(float(np.max(np.abs(np.asarray(x)-np.asarray(y)))) for x,y in zip(outputs['compiled'],outputs['eager']))
 (out/'inference.json').write_text(json.dumps(report,indent=2)+'\n')
network.configure_inference('compiled');network.evaluate_joint(features,own,opp)
try:
 with torch.profiler.profile(activities=[torch.profiler.ProfilerActivity.CPU,torch.profiler.ProfilerActivity.CUDA],record_shapes=True,profile_memory=True) as prof:
  for _ in range(3):network.evaluate_joint(features,own,opp)
  torch.cuda.synchronize()
 prof.export_chrome_trace('/tmp/pokemon-inference-trace.json')
 (out/'inference-kernels.txt').write_text(prof.key_averages().table(sort_by='self_cuda_time_total',row_limit=40))
 report['kernels']=[{'key':k.key,'count':k.count,'self_cpu_time_total_us':k.self_cpu_time_total,'self_device_time_total_us':k.self_device_time_total} for k in prof.key_averages()]
except Exception as e:report['profiler_error']=repr(e)
(out/'inference.json').write_text(json.dumps(report,indent=2)+'\n')
