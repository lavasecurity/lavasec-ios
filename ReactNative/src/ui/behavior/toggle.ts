import {useRef,useState} from 'react';
import type {LavaToggleRowProps} from '../contracts';

type ToggleRequestProps=Pick<LavaToggleRowProps,'onValueChange'|'disabled'|'pending'>;
/** Claim each gesture before owner callbacks; preserve explicit display policy. */
export function useToggleRequest({onValueChange,disabled=false,pending:externalPending=false}:ToggleRequestProps) {
  const pending=useRef(false);
  const [intent,setIntent]=useState<boolean>();
  const [resetRevision,setResetRevision]=useState(0);
  const change=(next:boolean)=>{
    if(disabled||externalPending||pending.current)return;
    // Own the gesture before invoking the parent. A synchronous native state
    // publication or another label/native event cannot dispatch it twice.
    pending.current=true;
    const finish=()=>{pending.current=false;setIntent(undefined);setResetRevision(revision=>revision+1);};
    let completion:ReturnType<typeof onValueChange>;
    try {completion=onValueChange(next);} catch(error) {finish();throw error;}
    if(completion&&typeof completion.then==='function'){
      setIntent(next);
      void completion.then(finish,finish);
    }else finish();
  };
  return {intent,resetRevision,change};
}
