"""Independent synthetic metadata fixtures; no candidate module is imported.

Only reviewed pure function definitions/constants from reporter AST are evaluated.
No SDK, application test, browser, worker, native Job helper or controller is loaded.
"""
from pathlib import Path
import ast
import copy
import hashlib
import json

ROOT=Path(__file__).absolute().parent


def main():
    source=(ROOT/'reporter_contract_reviewed.py').read_bytes()
    tree=ast.parse(source.decode('utf-8'))
    accepted=[]
    imports={'json','ntpath','re'}
    functions={'demand','integer','suite_path','validate_cache_refresh','validate_report','unique_object'}
    constants={'BOOTSTRAP_LINE','CACHE_BASE_SHA256','BROWSER_CACHE_STATUS'}
    for node in tree.body:
        if isinstance(node,ast.Import):
            assert all(alias.name in imports for alias in node.names)
            accepted.append(node)
        elif isinstance(node,ast.Assign):
            assert all(isinstance(target,ast.Name) and target.id in constants for target in node.targets)
            ast.literal_eval(node.value)
            accepted.append(node)
        elif isinstance(node,ast.FunctionDef):
            assert node.name in functions and not node.decorator_list
            assert not any(isinstance(child,(ast.Import,ast.ImportFrom,ast.Global,ast.Nonlocal)) for child in ast.walk(node))
            assert not any(isinstance(child,ast.Name) and child.id in {'open','exec','eval','compile','__import__','subprocess','os','sys','Path'} for child in ast.walk(node))
            accepted.append(node)
        else:
            assert isinstance(node,ast.Expr) and isinstance(node.value,ast.Constant) and isinstance(node.value.value,str)
    pure={}
    exec(compile(ast.Module(body=accepted,type_ignores=[]),'reviewed-pure-metadata-functions','exec'),pure)
    contract=json.loads((ROOT/'expected-cases.json').read_bytes())
    module=str(ROOT/'src/apps/guardian')
    events=[{'type':'start','time':0,'pid':12345,'protocolVersion':'0.1.1'},
            {'type':'allSuites','time':1,'count':3}]
    for suite_id,selector in enumerate(contract['selectors']):
        events.append({'type':'suite','time':2,'suite':{'id':suite_id,'platform':'chrome','path':selector}})
    next_id=10
    for suite_id,selector in enumerate(contract['selectors']):
        events += [{'type':'testStart','time':3,'test':{'id':next_id,'suiteID':suite_id,'name':'loading '+selector,'groupIDs':[]}},
                   {'type':'testDone','time':4,'testID':next_id,'result':'success','skipped':False,'hidden':True}]
        next_id+=1
    visible_start=len(events)
    for row in contract['cases']:
        suite_id=contract['selectors'].index(row['selector'])
        events += [{'type':'testStart','time':5,'test':{'id':next_id,'suiteID':suite_id,'name':row['name'],'groupIDs':[]}},
                   {'type':'testDone','time':6,'testID':next_id,'result':'success','skipped':False,'hidden':False}]
        next_id+=1
    # Real reporter time grows globally, including between test cases.
    for when,row in enumerate(events):
        row['time']=when
    events.append({'type':'done','time':len(events),'success':True})
    def encode(rows):
        return ('\n'.join(json.dumps(row,ensure_ascii=False) for row in rows)+'\n').encode('utf-8')
    validate=pure['validate_report']
    good=validate(encode(events),contract,module,0)
    assert good['suiteCount']==3 and good['visibleTests']==31 and len(good['hiddenSuccessfulTests'])==3
    negatives=[]
    def reject(name,change,native=0):
        rows=copy.deepcopy(events)
        change(rows)
        try:
            validate(encode(rows),contract,module,native)
        except (ValueError,UnicodeError):
            negatives.append(name)
        else:
            raise AssertionError('Invalid fixture accepted: '+name)
    done=visible_start+1
    reject('visible failure',lambda rows:rows[done].update(result='failure'))
    reject('visible error result',lambda rows:rows[done].update(result='error'))
    reject('visible skip',lambda rows:rows[done].update(skipped=True))
    reject('hidden expected case',lambda rows:rows[done].update(hidden=True))
    reject('missing visible case',lambda rows:rows.__delitem__(slice(visible_start,done+1)))
    reject('wrong visible name despite count',lambda rows:rows[visible_start]['test'].update(name='unexpected'))
    reject('duplicate visible name',lambda rows:rows[visible_start+2]['test'].update(name=rows[visible_start]['test']['name']))
    reject('late reporter error',lambda rows:rows.insert(-1,{'type':'error','time':rows[-2]['time'],'testID':rows[visible_start]['test']['id'],'error':'late'}))
    reject('missing completion',lambda rows:rows.pop(done))
    reject('duplicate completion',lambda rows:rows.insert(done,copy.deepcopy(rows[done])))
    reject('wrong Chrome suite',lambda rows:rows[2]['suite'].update(platform='vm'))
    reject('outside frozen suite path',lambda rows:rows[2]['suite'].update(path='D:/unrelated/'+contract['selectors'][0]))
    reject('duplicate physical suite',lambda rows:rows[3]['suite'].update(path=contract['selectors'][0]))
    reject('allSuites count other than physical three',lambda rows:rows[1].update(count=31))
    reject('duplicate allSuites',lambda rows:rows.insert(2,copy.deepcopy(rows[1])))
    reject('missing allSuites',lambda rows:rows.pop(1))
    reject('missing terminal done',lambda rows:rows.pop())
    reject('done unsuccessful',lambda rows:rows[-1].update(success=False))
    reject('done null',lambda rows:rows[-1].update(success=None))
    reject('event after done',lambda rows:rows.append({'type':'print','time':rows[-1]['time'],'testID':10,'messageType':'print','message':'late'}))
    reject('invented suiteDone event',lambda rows:rows.insert(-1,{'type':'suiteDone','time':rows[-2]['time'],'suiteID':0}))
    reject('unknown group ownership',lambda rows:rows[visible_start]['test'].update(groupIDs=[999]))
    reject('native nonzero despite perfect JSON',lambda rows:None,native=1)
    reject('native bool is not integer zero',lambda rows:None,native=False)
    reject('time moves backward',lambda rows:rows[done].update(time=0))
    for label,payload in [('malformed JSON',encode(events)+b'{bad\n'),('fatal infrastructure text',b'Unhandled exception: failed\n'+encode(events))]:
        try:
            validate(payload,contract,module,0)
        except ValueError:
            negatives.append(label)
        else:
            raise AssertionError('Invalid raw fixture accepted: '+label)
    base=json.loads(Path(contract['cacheBaseManifest']['path']).read_bytes())
    derived=json.loads((ROOT/'cache-content-chrome-refreshed.json').read_bytes())
    chrome=contract['approvedChromeExecutable']
    refresh=pure['validate_cache_refresh'](base,derived,chrome)
    chrome_index=next(i for i,row in enumerate(base['fixedFiles']) if Path(row['path'])==Path(chrome['path']))
    other_index=next(i for i,row in enumerate(base['fixedFiles']) if i != chrome_index)
    for label,change in [
        ('non-Chrome fixed SHA',lambda value:value['fixedFiles'][other_index].update(sha256='0'*64)),
        ('hosted library SHA',lambda value:value['trees'][0]['entries'][0].update(sha256='0'*64)),
        ('incorrect total bytes',lambda value:value['totals'].update(bytes=value['totals']['bytes']+1)),
        ('unapproved Chrome SHA',lambda value:value['fixedFiles'][chrome_index].update(sha256='0'*64)),
        ('missing original provenance',lambda value:value.pop('browserChromeRefresh'))]:
        bad=copy.deepcopy(derived)
        change(bad)
        try:
            pure['validate_cache_refresh'](base,bad,chrome)
        except ValueError:
            negatives.append(label)
        else:
            raise AssertionError('Invalid cache fixture accepted: '+label)
    report={'status':'INDEPENDENT_AST_PURE_METADATA_FIXTURES_ONLY_NOT_APPLICATION_VALIDATION',
       'reporterCodeSha256':hashlib.sha256(source).hexdigest(),'positiveReporterFixtures':1,'positiveCacheFixtures':1,
       'negativeFixtures':len(negatives),'rejectedFixtures':negatives,'goodSyntheticReport':good,'goodSyntheticCache':refresh,
       'candidateModulesImported':False,'onlyAllowlistedPureAstNodesEvaluated':True,
       'workerOrControllerOrNativeHelperLoaded':False,'sdkStarted':False,'browserStarted':False,'applicationTestsRun':False}
    with (ROOT/'independent-metadata-review.json').open('x',encoding='utf-8',newline='\n') as stream:
        json.dump(report,stream,ensure_ascii=False,indent=2)
        stream.write('\n')
    print(json.dumps({'status':report['status'],'negativeFixtures':len(negatives),'sdkStarted':False}))


if __name__=='__main__':
    main()
