import {act,renderHook} from '@testing-library/react-native';
import type {ActivityShareCardContent} from '../review/ActivityShareCard';
import {useActivityShare} from '../review/activity-share-actions';

const mockCommand=jest.fn();
const mockApp={command:mockCommand};
jest.mock('../review/ReviewContext',()=>({useReview:()=>({app:mockApp})}));
jest.mock('@react-navigation/native',()=>({useIsFocused:()=>true}));
const dates={start:1000,end:1100,label:'Matching range',includesToday:true};
const content:ActivityShareCardContent={token:'old-custom',payload:'https://apps.apple.com/app/lava-security/id6778022110',moduleCount:33,
  chart:'total',period:'custom',dateLabel:'January 1, 2026',startLabel:'January 1, 2026',endLabel:'January 1, 2026',
  allowed:2,blocked:1,uptime:'1m',buckets:[]};

test.each(['today','week','month'] as const)('changing Custom to %s with identical dates retires a pending query and a card awaiting capture',async period=>{
  for(const phase of ['query','render']) {
    let resolve!:(value:ActivityShareCardContent)=>void;
    const pending=new Promise<ActivityShareCardContent>(yes=>{resolve=yes;});
    mockCommand.mockReset().mockResolvedValue(null).mockImplementationOnce(()=>pending);
    const view=renderHook(({selected}:{selected:ActivityShareCardContent['period']})=>useActivityShare({dates,chart:'total',period:selected,loaded:true}),{initialProps:{selected:'custom' as ActivityShareCardContent['period']}});
    act(()=>view.result.current.exportChart());
    expect(view.result.current.busy).toBe(true);
    if(phase==='render')await act(async()=>resolve(content));
    view.rerender({selected:period});
    expect(view.result.current.busy).toBe(false);
    expect(view.result.current.content).toBeUndefined();
    if(phase==='query')await act(async()=>resolve(content));
    expect(mockCommand).not.toHaveBeenCalledWith(expect.objectContaining({type:'activity.share'}));
    // Retirement must also release the pending guard for a fresh selection.
    mockCommand.mockResolvedValueOnce({...content,token:'fresh-preset',period});
    await act(async()=>view.result.current.exportChart());
    expect(mockCommand).toHaveBeenLastCalledWith({type:'activity.card.query',start:dates.start,end:dates.end,hourly:period==='today',chart:'total',period});
    expect(view.result.current.content?.token).toBe('fresh-preset');
    await act(async()=>view.result.current.ready(true));
    expect(mockCommand).toHaveBeenCalledWith({type:'activity.share',token:'fresh-preset'});
    view.unmount();
  }
});
