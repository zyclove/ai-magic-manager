"""Synthetic reporter/manifest metadata only; never imports worker or starts SDK."""
from pathlib import Path
import copy
import importlib.util
import json

ROOT = Path(__file__).absolute().parent


def main():
    spec=importlib.util.spec_from_file_location('guardian_browser31_contract_metadata',ROOT/'reporter_contract.py')
    protocol=importlib.util.module_from_spec(spec)
    spec.loader.exec_module(protocol)
    contract=json.loads((ROOT/'expected-cases.json').read_bytes())
    module=str(ROOT/'src/apps/guardian')
    events=[{'type':'start','time':0,'pid':1,'protocolVersion':'0.1.1'},
            {'type':'allSuites','time':0,'count':3}]
    for suite_id,selector in enumerate(contract['selectors']):
        events.append({'type':'suite','time':0,'suite':{'id':suite_id,'platform':'chrome','path':selector}})
    test_id=10
    for suite_id,selector in enumerate(contract['selectors']):
        events.extend([{'type':'testStart','time':0,'test':{'id':test_id,'suiteID':suite_id,'name':'loading '+selector,'groupIDs':[]}},
                       {'type':'testDone','time':0,'testID':test_id,'result':'success','skipped':False,'hidden':True}])
        test_id+=1
    for row in contract['cases']:
        suite_id=contract['selectors'].index(row['selector'])
        events.extend([{'type':'testStart','time':0,'test':{'id':test_id,'suiteID':suite_id,'name':row['name'],'groupIDs':[]}},
                       {'type':'testDone','time':0,'testID':test_id,'result':'success','skipped':False,'hidden':False}])
        test_id+=1
    events.append({'type':'done','time':0,'success':True})
    def encode(rows):
        return ('\n'.join(json.dumps(row) for row in rows)+'\n').encode()
    good=protocol.validate_report(encode(events),contract,module,0)
    assert good['visibleTests']==31 and len(good['hiddenSuccessfulTests'])==3
    cases=[]
    visible_start=next(index for index,row in enumerate(events) if row['type']=='testStart' and not row['test']['name'].startswith('loading '))
    visible_done=visible_start+1
    def reject(name,change,native=0):
        rows=copy.deepcopy(events)
        change(rows)
        try:
            protocol.validate_report(encode(rows),contract,module,native)
        except (ValueError,UnicodeError):
            cases.append(name)
        else:
            raise AssertionError('Synthetic invalid reporter metadata accepted: '+name)
    reject('visible case failure',lambda rows:rows[visible_done].update(result='failure'))
    reject('visible case error',lambda rows:rows[visible_done].update(result='error'))
    reject('visible case skipped',lambda rows:rows[visible_done].update(skipped=True))
    reject('expected case hidden',lambda rows:rows[visible_done].update(hidden=True))
    reject('one visible case missing',lambda rows:rows.__delitem__(slice(visible_start,visible_done+1)))
    reject('same static count wrong actual name',lambda rows:rows[visible_start]['test'].update(name='unexpected application case'))
    reject('duplicate actual name replaces case',lambda rows:rows[visible_start+2]['test'].update(name=rows[visible_start]['test']['name']))
    reject('late reporter error after successful test',lambda rows:rows.insert(-1,{'type':'error','time':0,'testID':rows[visible_start]['test']['id'],'error':'late failure'}))
    reject('missing started-test completion',lambda rows:rows.pop(visible_done))
    reject('duplicate test completion',lambda rows:rows.insert(visible_done,copy.deepcopy(rows[visible_done])))
    reject('wrong suite platform',lambda rows:rows[2]['suite'].update(platform='vm'))
    reject('same basename outside frozen source',lambda rows:rows[2]['suite'].update(path='D:/unrelated/'+contract['selectors'][0]))
    reject('duplicate suite path',lambda rows:rows[3]['suite'].update(path=contract['selectors'][0]))
    reject('wrong allSuites count',lambda rows:rows[1].update(count=34))
    reject('duplicate allSuites',lambda rows:rows.insert(2,copy.deepcopy(rows[1])))
    reject('missing allSuites',lambda rows:rows.pop(1))
    reject('missing done',lambda rows:rows.pop())
    reject('done false',lambda rows:rows[-1].update(success=False))
    reject('done null',lambda rows:rows[-1].update(success=None))
    reject('event after done',lambda rows:rows.append({'type':'print','time':0,'testID':10,'messageType':'print','message':'late'}))
    reject('unknown event type',lambda rows:rows.insert(-1,{'type':'unknown','time':0}))
    reject('unknown group ownership',lambda rows:rows[visible_start]['test'].update(groupIDs=[999]))
    reject('native nonzero despite perfect JSON',lambda rows:None,native=1)
    for label,payload in [('malformed JSON',encode(events)+b'{bad\n'),('unexpected fatal text',b'Unhandled exception: compile failed\n'+encode(events))]:
        try:
            protocol.validate_report(payload,contract,module,0)
        except ValueError:
            cases.append(label)
        else:
            raise AssertionError('Synthetic invalid output accepted: '+label)
    base=json.loads(Path(contract['cacheBaseManifest']['path']).read_bytes())
    derived=json.loads((ROOT/'cache-content-chrome-refreshed.json').read_bytes())
    chrome=contract['approvedChromeExecutable']
    refresh=protocol.validate_cache_refresh(base,derived,chrome)
    chrome_index=next(index for index,row in enumerate(derived['fixedFiles']) if Path(row['path'])==Path(chrome['path']))
    for name,mutate in [
        ('unrelated fixed-file SHA changed',lambda value:value['fixedFiles'][-1].update(sha256='0'*64)),
        ('hosted library entry changed',lambda value:value['trees'][0]['entries'][0].update(sha256='0'*64)),
        ('total bytes mismatch',lambda value:value['totals'].update(bytes=value['totals']['bytes']+1)),
        ('unapproved Chrome SHA',lambda value:value['fixedFiles'][chrome_index].update(sha256='0'*64)),
    ]:
        bad=copy.deepcopy(derived)
        mutate(bad)
        try:
            protocol.validate_cache_refresh(base,bad,chrome)
        except ValueError:
            cases.append(name)
        else:
            raise AssertionError('Synthetic invalid cache metadata accepted: '+name)
    report={'status':'PURE_METADATA_REVIEW_ONLY_NOT_APPLICATION_TESTS','positiveSyntheticReporterCases':1,
       'positiveSyntheticChromeManifestCases':1,'rejectedSyntheticMutations':cases,'negativeCases':len(cases),
       'reporterContractResult':good,'cacheRefreshContractResult':refresh,
       'candidateWorkerImported':False,'sdkStarted':False,'chromeStarted':False,'applicationTestsRun':False}
    path=ROOT/'pure-metadata-review.json'
    with path.open('x',encoding='utf-8',newline='\n') as output:
        json.dump(report,output,indent=2)
        output.write('\n')
    print(json.dumps({'status':report['status'],'negativeCases':len(cases),'sdkStarted':False,'applicationTestsRun':False}))


if __name__=='__main__':
    main()
