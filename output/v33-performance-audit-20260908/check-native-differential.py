import json,random,sys,unittest
from pathlib import Path
import numpy as np
ROOT=Path('/home/cfcosta/Code/_tmp/pokemon/gpt');sys.path.insert(0,str(ROOT/'packages/battle-training'))
from battle_training import native
original=native.SEARCH_SERVER
candidate=Path('/tmp/pokemon-perf-isolated/battle-lean/.lake/build/bin/battleSearchServer')
a=native.SearchServer();native.SEARCH_SERVER=candidate;b=native.SearchServer();checks=0;transitions=0;divergences=0

def check(left,right):
 global checks,divergences
 for key in vars(left):
  if key=='handle':continue
  l,r=getattr(left,key),getattr(right,key)
  assert np.array_equal(l,r) if isinstance(l,np.ndarray) else l==r,(key,l,r)
 checks+=1;divergences+=int(left.divergence is not None)

rng=random.Random(20260908)
try:
 for episode in range(12):
  size1=episode%6+1;size2=(episode*5)%6+1
  left=a.reset(20260908,episode,size1,size2,level100=episode%2==0,balanced_final_species=True)
  right=b.reset(20260908,episode,size1,size2,level100=episode%2==0,balanced_final_species=True);check(left,right)
  for turn in range(30):
   if left.done:break
   pa=[i for i in range(13) if left.player_mask&(1<<i)];ea=[i for i in range(13) if left.enemy_mask&(1<<i)]
   actions=[(rng.choice(pa),rng.choice(ea),rng.getrandbits(64)) for _ in range(4)]
   ls=a.search_steps([(left.handle,*x) for x in actions]);rs=b.search_steps([(right.handle,*x) for x in actions])
   for l,r in zip(ls,rs):check(l,r)
   p,e,_=actions[0];left=a.episode_step(left.handle,p,e);right=b.episode_step(right.handle,p,e);check(left,right);transitions+=1
   left=a.compact_many([left])[0];right=b.compact_many([right])[0];check(left,right)
finally:a.close();b.close()
sys.path.insert(0,str(ROOT/'packages/battle-training/tests'))
suite=unittest.defaultTestLoader.loadTestsFromName('test_native_charge');result=unittest.TextTestRunner().run(suite)
assert result.wasSuccessful()
record={'baseline':str(original),'candidate':str(candidate),'snapshot_comparisons':checks,'episode_transitions':transitions,'matched_divergent_snapshots':divergences,'field_comparison':'All snapshot fields except process-local handle; feature arrays exact; hashes exact; search and actual episode paths.','native_charge_regression':'passed'}
(ROOT/'output/v33-performance-audit-20260908/native-differential.json').write_text(json.dumps(record,indent=2)+'\n');print(json.dumps(record,indent=2))
